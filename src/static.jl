module StaticMap

import ..Fallout
using Dates: Dates
using Serialization: Serialization
using TOML: TOML

const TIA = Fallout
const CACHE_FORMAT = "static-map-cache 5"
include("static_inference_walk.jl")
include("static_records.jl")
include("static_queries.jl")

"""Hash ordered settings for a portable cache key."""
cache_key_of(settings::AbstractVector{String})::String = bytes2hex(SHA.sha1(join(settings, '\n')))

"""One top-level testset: its name, the record key of its body, the parsed-code hash of the body and its source."""
struct TestsetSource
    name::String
    key::String
    body_hash::String
    text::String
end

"""A body compiled as a function: its signature, or why it did not compile (`failure` empty when it did)."""
struct BodyOutcome
    signature::Type
    failure::String
end

"""A serialized Salsa storage with an environment fingerprint."""
struct CacheEnvelope
    format::String
    key::String
    storage::Salsa.DefaultStorage
end

"""What `build` was asked for."""
struct Options
    root::String
    map_path::String
    tests::String
    sources::Vector{String}
    runner::String
    project::String
    commit::String
    mode::WalkMode
    cache_directory::String
    workers::Int
    setup_file::String
    test_module::String
    extra_testset_macros::Vector{String}
    progress_interval::Int
end

"""The part of a tracked file that is not a testset: its functions, the identifiers each function mentions, its other items, and the code of each name its bindings define."""
struct FileInventory
    path::String
    functions::Vector{Definition}
    others::Vector{OtherItem}
end

"""Whether an item invokes a configured testset macro."""
extra_testset_item(item::TIA.Item, macros::AbstractVector{String})::Bool = item.kind == :other && any(macro_spec -> occursin(string("@", macro_name(macro_spec)), item.text), macros)

"""The tracked file `path`'s functions with their code hashes and the identifiers each mentions, its other items, and its bindings' code; its testsets and its `export` lists (which do not change what inference sees) are left out."""
function file_inventory(snapshot::TIA.Snapshot, path::AbstractString, source::Bool, macros::AbstractVector{String})::FileInventory
    items = TIA.items_at(snapshot, path, true)
    functions = [item for item in items if item.kind == :function]
    definitions = [Definition(String(path), item.header, item.first, item.last, source, ast_hash(item.text)) for item in functions]
    others = [OtherItem(String(path), String(item.name), ast_hash(item.text), other_mentions(item.text)) for item in items if item.kind != :function && item.kind != :testset && !extra_testset_item(item, macros) && !startswith(item.text, "export ")]
    return FileInventory(String(path), definitions, others)
end

"""Read a Salsa storage only when its format and environment match."""
function read_cache(path::AbstractString, expected_key::AbstractString)::Salsa.DefaultStorage
    if isempty(path) || !isfile(path)
        return Salsa.DefaultStorage()
    end
    loaded = try
        Base.invokelatest(Serialization.deserialize, path)
    catch # lint: broad-catch  a damaged or older cache file can fail to read any way; the walk then starts afresh
        nothing
    end
    if loaded isa CacheEnvelope && loaded.format == CACHE_FORMAT && loaded.key == expected_key
        return loaded.storage
    end
    return Salsa.DefaultStorage()
end

"""Name a worker's cache file under its environment key."""
function cache_file(directory::AbstractString, key::AbstractString, part::Integer, parts::Integer)::String
    if isempty(directory)
        return ""
    end
    return joinpath(directory, string(key, "-", part, "-of-", parts, ".jls"))
end

"""Atomically persist Salsa storage."""
function write_cache(
        directory::AbstractString, key::AbstractString, part::Integer,
        parts::Integer, storage::Salsa.DefaultStorage,
    )::Nothing
    if isempty(directory)
        return nothing
    end
    mkpath(directory)
    file = cache_file(directory, key, part, parts)
    partial = string(file, ".", getpid())
    Serialization.serialize(partial, CacheEnvelope(CACHE_FORMAT, String(key), storage))
    mv(partial, file; force = true)
    return nothing
end

"""Every `.jl` file under `directory` of `root`, relative to `root`."""
tracked_files(root::AbstractString, directory::AbstractString)::Vector{String} = TIA.jl_files(root, directory)

"""Extract top-level testsets and configured extra testset macros."""
function testset_sources(located::AbstractVector{TIA.Located}, macros::AbstractVector{String})::Vector{TestsetSource}
    found = Pair{String, String}[]
    for entry in located
        item = entry.item
        if item.kind == :testset
            found = vcat(found, item.name => item.text)
        elseif extra_testset_item(item, macros)
            names = extra_testset_names(Meta.parse(item.text), macros)
            found = vcat(found, [name => item.text for name in names])
        end
    end
    occurrences = Dict{String, Int}()
    sources = TestsetSource[]
    for (name, text) in found
        count = get(occurrences, name, 0) + 1
        occurrences[name] = count
        sources = vcat(sources, TestsetSource(name, string("testset:", name, '#', count), ast_hash(text), text))
    end
    return sources
end

"""
    compile_body(test_module, source, index, options.extra_testset_macros)

The testset's body as a function of no arguments in `test_module`, with its testset macros
replaced by their bodies and its `using` and `import` statements run in `test_module` first
(a function body cannot hold them). A body that cannot be a function (a `const` in it) is a
failure with the lowering error.
"""
function compile_body(test_module::Module, source::TestsetSource, index::Int, macros::AbstractVector{String})::BodyOutcome
    name = Symbol("__static_body_", index)
    parsed = without_testsets(Meta.parse(source.text), macros)
    definition = Expr(:function, Expr(:call, name), Expr(:block, without_imports(parsed)))
    failure = try
        for statement in hoisted_imports(parsed)
            Core.eval(test_module, statement)
        end
        Core.eval(test_module, definition)
        ""
    catch exception # lint: broad-catch  a testset body can fail to compile any way; the map records it as uncompiled
        sprint(showerror, exception)
    end
    if !isempty(failure)
        return BodyOutcome(Tuple{}, failure)
    end
    return BodyOutcome(Tuple{typeof(Base.invokelatest(getglobal, test_module, name))}, "")
end

"""
Drop top-level testset calls while loading definitions from test files. A testset inside a
function definition (a helper that runs one) is replaced by its body instead, as in a compiled
testset body, so the helper still reaches what its testset calls.
"""
struct DropTestsets <: Function
    macros::Vector{String}
end

"""Whether `expression` defines a function or a macro: `function f() … end`, `f() = …`, `() -> …`."""
function function_definition(expression::Expr)::Bool
    if expression.head in (:function, :macro, :->)
        return true
    end
    if expression.head === :(=) && first(expression.args) isa Expr
        signature = first(expression.args)
        while signature isa Expr && signature.head in (:where, :(::))
            signature = first(signature.args)
        end
        return signature isa Expr && signature.head === :call
    end
    return false
end

function (mapper::DropTestsets)(expression::Expr)::Any
    if function_definition(expression)
        return without_testsets(expression, mapper.macros)
    end
    if expression.head === :macrocall
        head = first(expression.args)
        if head isa Symbol
            name = String(head)
            if name == "@testset" || name in string.("@", macro_name.(mapper.macros))
                return nothing
            end
        end
    end
    if expression.head === :call && first(expression.args) === :include
        path = mapper(last(expression.args))
        if length(expression.args) == 3
            return :(Main.Fallout.StaticMap.transformed_include(@__MODULE__, $path, $(mapper.macros), $(mapper(expression.args[2]))))
        end
        return :(Main.Fallout.StaticMap.transformed_include(@__MODULE__, $path, $(mapper.macros)))
    end
    return Expr(expression.head, Any[mapper(argument) for argument in expression.args]...)
end
(::DropTestsets)(expression::Any)::Any = expression

"""Include a test file after removing its testset calls, after the file's own `mapexpr` when it names one."""
function transformed_include(test_module::Module, path::AbstractString, macros::AbstractVector{String}, mapexpr::Function = identity)::Any
    mapper = DropTestsets(String[macros...])
    return Base.include(expression -> mapper(mapexpr(expression)), test_module, path)
end

"""Load the definitions of a test suite or include a caller-provided setup file."""
function load_test_module(options::Options)::Module
    if !isempty(options.setup_file)
        transformed_include(Main, joinpath(options.root, options.setup_file), options.extra_testset_macros)
    else
        module_name = Symbol(options.test_module)
        Core.eval(Main, Expr(:module, true, module_name, Expr(:block)))
        test_module = Base.invokelatest(getglobal, Main, module_name)::Module
        Core.eval(test_module, :(import Main.Fallout))
        macros = options.extra_testset_macros
        transformed_include(test_module, joinpath(options.root, options.tests), macros)
    end
    name = Symbol(options.test_module)
    if !isdefined(Main, name)
        error("--test-module ", options.test_module, " was not defined by test setup")
    end
    return Base.invokelatest(getglobal, Main, name)
end

"""Find the package module loaded by the test module."""
function source_module(options::Options, test_module::Module)::Module
    project = TOML.parsefile(joinpath(options.root, "Project.toml"))
    name = Symbol(project["name"])
    if isdefined(test_module, name)
        return Base.invokelatest(getglobal, test_module, name)::Module
    end
    return Base.require(Main, name)::Module
end

"""Build a Fallout map from reached source functions."""
function map_document(
        options::Options, definitions::AbstractVector{Definition}, source_files::AbstractVector{String},
        outcomes::AbstractDict{String, Tuple{String, Set{Int}}}, everything::AbstractSet{String},
    )::Dict{String, Any}
    source_numbers = [number for (number, definition) in enumerate(definitions) if definition.source]
    file_start = Dict{String, Int}()
    for number in source_numbers
        get!(file_start, definitions[number].file, number)
    end
    headers = Dict{String, Any}(file => String[definition.header for definition in definitions if definition.source && definition.file == file] for file in source_files)
    testsets = Dict{String, Any}()
    for (name, (status, numbers)) in outcomes
        reached = if name in everything
            Set(source_numbers)
        else
            numbers
        end
        by_file = Dict{String, Vector{Int}}()
        for number in reached
            definition = definitions[number]
            if definition.source
                by_file[definition.file] = vcat(get(by_file, definition.file, Int[]), number - file_start[definition.file] + 1)
            end
        end
        testsets[name] = Dict{String, Any}(
            "status" => status,
            "ms" => 0,
            "functions" => Dict{String, Any}(file => TIA.ranges_text(indexes) for (file, indexes) in by_file),
        )
    end
    return Dict{String, Any}(
        "meta" => Dict{String, Any}(
            "commit" => options.commit,
            "built" => string(Dates.now()),
            "julia" => string(VERSION),
            "tests" => options.tests,
            "runner" => options.runner,
            "project" => options.project,
            "suites" => "",
            "suite_pattern" => TIA.DEFAULT_SUITE_PATTERN,
            "sources" => options.sources,
            "static" => mode_name(options.mode),
            "setup_file" => options.setup_file,
            "test_module" => options.test_module,
            "extra_testset_macros" => options.extra_testset_macros,
            "cache" => options.cache_directory,
            "builder_fingerprint" => builder_fingerprint(),
            "environment" => Fallout.environment_digest(options.root, options.sources, options.project),
        ),
        "definitions" => headers,
        "testsets" => testsets,
    )
end

"""Reject source, environment, and test edits relative to the credited commit."""
function check_build_tree(options::Options)::Nothing
    tests_dir = dirname(options.tests)
    uncommitted = String[
        change.path for change in TIA.file_changes(options.root, options.commit, "")
            if endswith(change.path, ".jl") ||
            TIA.dependency_file(change.path, options.sources, options.project) ||
            startswith(change.path, string(tests_dir, "/"))
    ]
    if !isempty(uncommitted)
        error("the working tree differs from commit ", options.commit, " in ", join(uncommitted, ", "), "; commit the changes first, since the map credits its reach to that commit")
    end
    return nothing
end

"""Source definitions, test bodies, and Salsa input hashes for a build."""
struct Preparation
    source_files::Vector{String}
    definitions::Vector{Definition}
    placements::Placements
    sources::Vector{TestsetSource}
    cache_key::String
    file_hashes::Dict{String, String}
    inventory_hash::String
end

"""A worker's testset reach results and query counts."""
struct PartialWalk
    results::Dict{String, ReachResult}
    failures::Dict{String, String}
    frame_runs::Int
    reach_runs::Int
end

"""Collect tracked definitions and source hashes without loading the package."""
function prepare(options::Options)::Preparation
    snapshot = TIA.Snapshot(options.root, "")
    located = TIA.located_items(snapshot, options.tests)
    test_files = unique(String[entry.path for entry in located])
    source_files = collect(String, Iterators.flatten((tracked_files(options.root, directory) for directory in options.sources)))
    files = unique(vcat(source_files, test_files))
    inventories = FileInventory[
        file_inventory(snapshot, path, path in source_files, options.extra_testset_macros)
            for path in files
    ]
    definitions = collect(Definition, Iterators.flatten((inventory.functions for inventory in inventories)))
    placements = placements_of(options.root, definitions)
    sources = testset_sources(located, options.extra_testset_macros)
    if isempty(sources)
        error("no top-level testsets found in ", options.tests)
    end
    if any(source -> isempty(source.name), sources)
        error("a testset has a computed name")
    end
    file_hashes = Dict{String, String}(path => ast_hash(TIA.read_file(snapshot, path)) for path in files)
    others = collect(OtherItem, Iterators.flatten((inventory.others for inventory in inventories)))
    inventory_hash = cache_key_of(String[string(item.file, ':', item.name, ':', item.hash) for item in others])
    environments = String[
        read(joinpath(folder, name), String)
            for folder in (options.root, joinpath(options.root, "test"))
            if isdir(folder)
            for name in readdir(folder)
            if name == "Project.toml" || (startswith(name, "Manifest") && endswith(name, ".toml"))
    ]
    setup_files = if isempty(options.setup_file)
        String[]
    else
        unique(String[entry.path for entry in TIA.located_items(snapshot, options.setup_file)])
    end
    setup_hashes = String[string(path, ':', TIA.read_file(snapshot, path)) for path in setup_files if !(path in files)]
    walker = walker_sources()
    fallout_version = String(TOML.parsefile(joinpath(dirname(@__DIR__), "Project.toml"))["version"])
    key = cache_key_of(vcat(String[CACHE_FORMAT, string(VERSION), fallout_version, mode_name(options.mode), options.setup_file, options.test_module, join(options.extra_testset_macros, ","), join(definition_identities(definitions), "\n"), join((source.key for source in sources), "\n")], environments, setup_hashes, walker))
    println(stderr, "[static_map] ", length(sources), " testsets, ", length(definitions), " functions")
    return Preparation(source_files, definitions, placements, sources, key, file_hashes, inventory_hash)
end

"""Read the static walker's source files for cache and map validation."""
walker_sources()::Vector{String} = String[read(joinpath(@__DIR__, name), String) for name in ("static.jl", "static_reach.jl", "static_reach_114.jl", "static_records.jl", "static_queries.jl", "static_inference_walk.jl")]

"""Identify the walker implementation and its Julia and Fallout versions."""
function builder_fingerprint()::String
    fallout_version = String(TOML.parsefile(joinpath(dirname(@__DIR__), "Project.toml"))["version"])
    return cache_key_of(vcat(String[CACHE_FORMAT, string(VERSION), fallout_version], walker_sources()))
end

"""Print completed testsets at a fixed interval during a local walk."""
struct ProgressPrinter <: Function
    done::Threads.Atomic{Int}
    total::Int
    started::UInt64
end

function (printer::ProgressPrinter)(::Timer)::Nothing
    println(
        stderr, "[static_map] progress ", printer.done[], "/", printer.total,
        " testsets, ", round((time_ns() - printer.started) / 1.0e9; digits = 1), " s"
    )
    return nothing
end

"""Compile selected test bodies, then query their reach through Salsa."""
function walk_part(
        options::Options, preparation::Preparation, part::Integer, parts::Integer,
        started::UInt64, progress_file::AbstractString = ""
    )::PartialWalk
    loading = time_ns()
    test_module = load_test_module(options)
    println(stderr, "[static_map] test module loaded in ", round((time_ns() - loading) / 1.0e9; digits = 1), " s")
    selected = Pair{Int, TestsetSource}[
        index => source for (index, source) in enumerate(preparation.sources) if in_part(index, part, parts)
    ]
    compiled = Pair{TestsetSource, BodyOutcome}[
        source => compile_body(test_module, source, index, options.extra_testset_macros)
            for (index, source) in selected
    ]
    scope = Scope(
        Module[source_module(options, test_module), test_module],
        String[joinpath(realpath(options.root), directory) * "/" for directory in options.sources]
    )
    cache_path = cache_file(options.cache_directory, preparation.cache_key, part, parts)
    storage = read_cache(cache_path, preparation.cache_key)
    signatures = cached_signatures(storage)
    context = QueryContext(
        options.mode, scope, preparation.placements, signatures,
        Threads.Atomic{Int}(0), Threads.Atomic{Int}(0)
    )
    runtime = Salsa.Runtime{typeof(context), Salsa.DefaultStorage}(context, storage)
    for (path, hash) in preparation.file_hashes
        set_source_code_hash!(runtime, path, hash)
    end
    set_method_inventory_hash!(runtime, preparation.inventory_hash)
    for (source, _) in compiled
        set_testset_code_hash!(runtime, source.key, source.body_hash)
    end
    results = Dict{String, ReachResult}()
    failures = Dict{String, String}()
    done = Threads.Atomic{Int}(0)
    timer = Timer(
        ProgressPrinter(done, length(compiled), started), options.progress_interval;
        interval = options.progress_interval
    )
    try
        for (source, outcome) in compiled
            if isempty(outcome.failure)
                results[source.key] = testset_reach(runtime, source.key, outcome.signature)
            else
                failures[source.key] = outcome.failure
            end
            Threads.atomic_add!(done, 1)
            if !isempty(progress_file)
                # Written whole and renamed into place, so the parent never reads a partial count.
                write(string(progress_file, ".partial"), string(done[]))
                mv(string(progress_file, ".partial"), progress_file; force = true)
            end
        end
    finally
        close(timer)
    end
    write_cache(options.cache_directory, preparation.cache_key, part, parts, storage)
    println(stderr, "[static_map] progress ", done[], "/", length(compiled), " testsets, ", round((time_ns() - started) / 1.0e9; digits = 1), " s")
    println(stderr, "[static_map] inferred ", context.frame_runs[], " frames; recalculated ", context.reach_runs[], " testsets")
    return PartialWalk(results, failures, context.frame_runs[], context.reach_runs[])
end

"""Memory a worker process needs: the test module, the compiled bodies and the inferred frames of its testsets."""
const WORKER_MEMORY = 4 * 2^30

"""Testsets that make another worker process worth its start-up (loading the test module takes about 20 s)."""
const TESTSETS_PER_WORKER = 8

"""How many processes walk `testsets` testsets: `options.workers`, else as many as memory, half this process's threads
(the cores its job holds) and the work allow."""
function worker_count(options::Options, testsets::Integer)::Int
    if options.workers > 0
        return min(options.workers, testsets)
    end
    return max(1, min(Sys.total_memory() ÷ WORKER_MEMORY, Threads.nthreads() ÷ 2, cld(testsets, TESTSETS_PER_WORKER)))
end

"""The command line of worker `part` of `parts`: this build's options, and the file its walk goes to."""
function worker_command(options::Options, part::Integer, parts::Integer, partial::AbstractString, threads::Integer)::Cmd
    sources = collect(String, Iterators.flatten((["--source", source] for source in options.sources)))
    cache = if isempty(options.cache_directory)
        "none"
    else
        options.cache_directory
    end
    macros = collect(String, Iterators.flatten((["--extra-testset-macro", macro_spec] for macro_spec in options.extra_testset_macros)))
    arguments = ["--static-worker", "--root", options.root, "--tests", options.tests, "--runner", options.runner, "--project", options.project, "--commit", options.commit, "--unresolved", mode_name(options.mode), "--cache", cache, "--part", string(part, '/', parts), "--partial", partial, "--progress-file", string(partial, ".progress"), "--setup-file", options.setup_file, "--test-module", options.test_module, "--progress-interval", string(options.progress_interval), sources..., macros...]
    return `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) --threads=$threads $(joinpath(@__DIR__, "..", "bin", "fallout.jl")) $arguments`
end

"""
    walk_in_workers(options, workers, total)

Walk the `total` testsets to walk in `workers` processes, each a part of them, and read back what each walked.
A process infers on about 1.5 cores whatever its thread count, which is why the walk is split by process.
"""
function walk_in_workers(options::Options, workers::Integer, total::Integer)::Vector{PartialWalk}
    # A directory of this build's own, so concurrent builds of one root do not share files.
    directory = mktempdir()
    try
        return walk_in_directory(options, workers, total, directory)
    finally
        rm(directory; recursive = true, force = true)
    end
end

"""The walk of `walk_in_workers`, its workers' files in `directory`."""
function walk_in_directory(options::Options, workers::Integer, total::Integer, directory::AbstractString)::Vector{PartialWalk}
    partials = String[joinpath(directory, string("part-", part, ".jls")) for part in 1:workers]
    logs = String[joinpath(directory, string("part-", part, ".log")) for part in 1:workers]
    threads = clamp(Threads.nthreads() ÷ workers, 1, 4)
    processes = [run(pipeline(worker_command(options, part, workers, partials[part], threads); stdout = logs[part], stderr = logs[part]); wait = false) for part in 1:workers]
    started = time_ns()
    while any(Base.process_running, processes)
        sleep(options.progress_interval)
        completed = sum(something(tryparse(Int, read(path, String)), 0) for path in string.(partials, ".progress") if isfile(path); init = 0)
        println(
            stderr, "[static_map] progress ", completed, "/", total,
            " testsets across ", workers, " workers, ", round((time_ns() - started) / 1.0e9; digits = 1), " s"
        )
    end
    foreach(wait, processes)
    for part in 1:workers
        for line in eachline(logs[part])
            if startswith(line, "[static_map]")
                println(stderr, "[worker ", part, "/", workers, "] ", line)
            end
        end
    end
    failed = [part for (part, process) in enumerate(processes) if !success(process)]
    for part in failed
        println(stderr, "[static_map] worker ", part, " failed; the end of ", logs[part], ":\n", join(last(readlines(logs[part]), 40), '\n'))
    end
    if !isempty(failed)
        error("static map workers ", failed, " failed")
    end
    return PartialWalk[Serialization.deserialize(partial) for partial in partials]
end

"""Build a static map from Salsa reach queries and write Fallout's map format."""
function build(options::Options)::Nothing
    started = time_ns()
    preparation = prepare(options)
    workers = worker_count(options, length(preparation.sources))
    walks = if workers == 1
        PartialWalk[walk_part(options, preparation, 1, 1, started)]
    else
        walk_in_workers(options, workers, length(preparation.sources))
    end
    results = Dict{String, ReachResult}()
    failures = Dict{String, String}()
    for walk in walks
        merge!(results, walk.results)
        merge!(failures, walk.failures)
    end
    outcomes = Dict{String, Tuple{String, Set{Int}}}()
    everything = Set{String}()
    unresolved = Set{String}()
    unmapped = Set{String}()
    for source in preparation.sources
        status, previous = get(outcomes, source.name, ("ok", Set{Int}()))
        if !haskey(results, source.key)
            # One body of a repeated name that did not compile leaves the name's reach unknown.
            outcomes[source.name] = ("no-coverage", previous)
            continue
        end
        reached = results[source.key]
        outcomes[source.name] = (status, union(previous, reached.positions))
        if reached.everything
            everything = union(everything, Set{String}([source.name]))
        end
        unresolved = union(unresolved, reached.unresolved)
        unmapped = union(unmapped, reached.unmapped)
    end
    document = map_document(options, preparation.definitions, preparation.source_files, outcomes, everything)
    buffer = IOBuffer()
    TOML.print(buffer, document; sorted = true)
    mkpath(dirname(options.map_path))
    write(options.map_path, take!(buffer))
    for (key, failure) in failures
        println(stderr, "[static_map] no body for ", key, ": ", first(failure, 160))
    end
    println(
        stderr, "[static_map] wrote ", options.map_path, ": ", length(preparation.sources),
        " testsets, ", length(unresolved), " unresolved labels, ", length(unmapped), " unmapped methods"
    )
    println(
        stderr, "[static_map] inferred ", sum(walk.frame_runs for walk in walks),
        " frames; recalculated ", sum(walk.reach_runs for walk in walks), " testsets"
    )
    println(stderr, "[static_map] elapsed ", round((time_ns() - started) / 1.0e9; digits = 1), " s")
    return nothing
end

"""Walk one part of the testsets to walk and write what was walked to `--partial`: one worker of `walk_in_workers`."""
function walk_part_command(args::AbstractVector{<:AbstractString})::Nothing
    started = time_ns()
    options = parse_options(args)
    part, parts = parse.(Int, split(option_value(args, "--part", "1/1"), '/'))
    preparation = prepare(options)
    walked = walk_part(options, preparation, part, parts, started, option_value(args, "--progress-file", ""))
    Serialization.serialize(option_value(args, "--partial", ""), walked)
    return nothing
end

"""The values of `flag` in `args`."""
function option_values(args::AbstractVector{<:AbstractString}, flag::AbstractString)::Vector{String}
    positions = findall(==(flag), args)
    if any(position == lastindex(args) for position in positions)
        error(flag, " needs a value")
    end
    return String[args[position + 1] for position in positions]
end

"""The last value of `flag` in `args`, or `fallback`."""
function option_value(args::AbstractVector{<:AbstractString}, flag::AbstractString, fallback::AbstractString)::String
    values = option_values(args, flag)
    if isempty(values)
        return String(fallback)
    end
    return last(values)
end

"""The walk mode `--unresolved` names."""
function walk_mode(name::AbstractString)::WalkMode
    if name == "drop"
        return DropUnresolved()
    end
    if name == "follow-known"
        return FollowKnown()
    end
    if name == "approximate"
        return FollowUnresolved()
    end
    error("invalid unresolved mode: ", name)
end

"""The `--unresolved` name of a walk mode."""
mode_name(::DropUnresolved)::String = "drop"
mode_name(::FollowKnown)::String = "follow-known"
mode_name(::FollowUnresolved)::String = "approximate"

"""Parse the command line into `Options`."""
function parse_options(args::AbstractVector{<:AbstractString})::Options
    root = abspath(option_value(args, "--root", pwd()))
    sources = option_values(args, "--source")
    mode = option_value(args, "--unresolved", "approximate")
    if !(mode in ("drop", "follow-known", "approximate"))
        error("--unresolved is drop, follow-known or approximate, not ", mode)
    end
    commit = option_value(args, "--commit", "")
    if isempty(commit)
        commit = strip(TIA.git(root, "rev-parse", "HEAD"))
    end
    cache = option_value(args, "--cache", joinpath(root, ".scratch", "static-map-cache"))
    return Options(
        root,
        abspath(root, option_value(args, "--map", TIA.DEFAULT_MAP)),
        option_value(args, "--tests", "test/runtests.jl"),
        if isempty(sources)
            ["src"]
        else
            sources
        end,
        option_value(args, "--runner", "test/retest.jl"),
        option_value(args, "--project", "."),
        commit,
        walk_mode(mode),
        ifelse(cache == "none", "", abspath(root, cache)),
        parse(Int, option_value(args, "--workers", "0")),
        option_value(args, "--setup-file", ""),
        option_value(args, "--test-module", "StaticMapTests"),
        option_values(args, "--extra-testset-macro"),
        parse(Int, option_value(args, "--progress-interval", "10")),
    )
end

"""The separator for Julia's environment path lists on each platform."""
function load_path_separator(windows::Bool)::Char
    if windows
        return ';'
    end
    return ':'
end

"""Run a static build in the package project's environment."""
function build_subprocess(args::AbstractVector{<:AbstractString})::Nothing
    root = abspath(option_value(args, "--root", pwd()))
    project = option_value(args, "--project", ".")
    project_path = abspath(root, project)
    separator = load_path_separator(Sys.iswindows())
    fallout_root = dirname(@__DIR__)
    load_path = join((project_path, fallout_root, "@stdlib"), separator)
    script = joinpath(fallout_root, "bin", "fallout.jl")
    # The child runs in `root`, so a relative `--root` would be read against itself: the last value wins.
    arguments = vcat(String[args...], String["--root", root])
    command = Cmd(`$(Base.julia_cmd()) --startup-file=no --project=$project_path $script --static-build $arguments`; dir = root)
    run(addenv(command, "JULIA_LOAD_PATH" => load_path))
    return nothing
end

"""
    build_at_commit(root, commit, map_path, args)

Build the static map of `commit` to `map_path` in a temporary checkout of it, so neither edits in
the working tree (which `select` then diffs from `commit`) nor commits after it are credited to the
map. Environment files the checkout lacks (an untracked Manifest) are copied from `root`.
"""
function build_at_commit(root::AbstractString, commit::AbstractString, map_path::AbstractString, args::AbstractVector{<:AbstractString})::Nothing
    cache = option_value(args, "--cache", joinpath(".scratch", "static-map-cache"))
    if cache != "none"
        cache = abspath(root, cache)
    end
    toplevel = realpath(strip(TIA.git(root, "rev-parse", "--show-toplevel")))
    checkout = mktempdir()
    tree = joinpath(checkout, "tree")
    TIA.git(root, "worktree", "add", "--detach", "--quiet", tree, commit)
    try
        tree_root = normpath(joinpath(tree, relpath(realpath(root), toplevel)))
        copy_environments(root, tree_root, option_value(args, "--project", "."))
        build_subprocess(vcat(String[args...], String["--root", tree_root, "--map", String(map_path), "--cache", cache, "--commit", String(commit)]))
    finally
        TIA.git(root, "worktree", "remove", "--force", tree)
        rm(checkout; recursive = true, force = true)
    end
    return nothing
end

"""Copy the `Project.toml` and `Manifest*.toml` files of `root`, its project and its `test` folder that `tree` lacks."""
function copy_environments(root::AbstractString, tree::AbstractString, project::AbstractString)::Nothing
    for folder in unique(normpath.(String[".", project, "test"]))
        source = joinpath(root, folder)
        for name in (isdir(source) ? readdir(source) : String[])
            environment = name == "Project.toml" || (startswith(name, "Manifest") && endswith(name, ".toml"))
            target = joinpath(tree, folder, name)
            if environment && !ispath(target)
                mkpath(dirname(target))
                cp(joinpath(source, name), target)
            end
        end
    end
    return nothing
end

"""
Build a missing or outdated static map before selecting tests: an absent map is built at `HEAD`, a
static map from another walker or Julia is rebuilt at its own commit with its recorded options. A
static map stays at its commit when `HEAD` moves, as a coverage map does, so `select` still diffs
from it and sees the commits since.
"""
function ensure_map(
        root::AbstractString, map_path::AbstractString,
        args::AbstractVector{<:AbstractString}
    )::Nothing
    if !isfile(map_path)
        build_at_commit(root, strip(TIA.git(root, "rev-parse", "HEAD")), map_path, args)
        return nothing
    end
    document = TOML.parsefile(map_path)
    meta = document["meta"]
    if !haskey(meta, "static") || get(meta, "builder_fingerprint", "") == builder_fingerprint()
        return nothing
    end
    build_at_commit(root, String(meta["commit"]), map_path, vcat(rebuild_options(root, meta), String[args...]))
    return nothing
end

"The `build` arguments that rebuild a static map with the options recorded in its `meta`."
function rebuild_options(root::AbstractString, meta::AbstractDict)::Vector{String}
    sources = collect(String, Iterators.flatten((["--source", String(source)] for source in meta["sources"])))
    macros = collect(String, Iterators.flatten((["--extra-testset-macro", String(name)] for name in get(meta, "extra_testset_macros", String[]))))
    cache_option = String(get(meta, "cache", joinpath(root, ".scratch", "static-map-cache")))
    if isempty(cache_option)
        cache_option = "none"
    end
    settings = String[
        "build", "--static",
        "--tests", String(meta["tests"]), "--runner", String(meta["runner"]),
        "--project", String(get(meta, "project", ".")), "--unresolved", String(meta["static"]),
        "--setup-file", String(get(meta, "setup_file", "")),
        "--test-module", String(get(meta, "test_module", "StaticMapTests")),
        "--cache", cache_option,
    ]
    return vcat(settings, sources, macros)
end

end # module StaticMap
