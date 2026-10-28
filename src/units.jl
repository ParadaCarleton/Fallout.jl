# ---------------------------------------------------------------------------------------
# Units: cached pieces of a long test, reused while the code they ran is unchanged
# ---------------------------------------------------------------------------------------

using Serialization: serialize, deserialize
using StableHashTraits: stable_hash

"An item of the tree a unit cache watches, with its file and the digest of its code."
struct Digested
    path::String
    item::Item
    digest::String
end

"""
The code a unit's result depends on: for each file, the digests of the items it ran, and
for each name those items mention, the digest of that name's definitions (`""` when none).
`result` names the stored result file by its digest.
"""
struct UnitRecord
    items::Dict{String, Vector{String}}
    names::Dict{String, String}
    result::String
end

"""
    UnitCache

Where units store results (`dir`) and the tree whose code they depend on (`root`), parsed
when the cache was made. `track` is `:coverage` (a unit depends on the code it ran or
compiled) or `:sources` (on every file under `root`). `environment` digests Julia's version,
the projects, manifests and preferences. `refresh` recomputes every unit. `owners` maps
each method defined under `root` to the item that defines it.
"""
struct UnitCache
    dir::String
    root::String
    track::Symbol
    refresh::Bool
    environment::String
    items::Vector{Digested}
    names::Dict{String, String}
    mentions::Dict{String, Set{String}}
    owners::Dict{Method, Digested}
end

"One line of an LCOV tracefile: its file as Julia names it, its number and its count."
struct CoveredLine
    file::String
    line::Int
    count::Int
end

"Units compute one at a time under coverage: a coverage snapshot sees every thread."
const COMPUTING = ReentrantLock()

function sha1_text(parts::AbstractVector{<:AbstractString})::String
    return bytes2hex(SHA.sha1(join(parts, '\0')))
end

"The text of `path`, or empty when there is no such file."
function file_text(path::Union{Nothing, AbstractString})::String
    if isnothing(path) || !isfile(path)
        return ""
    end
    return read(path, String)
end

"""
The digest of Julia's version and the project, manifest and preferences of `project` and
of every environment on the load path.
"""
function environment_digest(project::AbstractString)::String
    files = [
        file
            for environment in filter(isfile, unique(vcat(project, Base.load_path())))
            for file in (
                environment,
                Base.project_file_manifest_path(environment),
                joinpath(dirname(environment), "LocalPreferences.toml"),
                joinpath(dirname(environment), "JuliaLocalPreferences.toml"),
            )
    ]
    return sha1_text(vcat(string(VERSION), file_text.(files)))
end

"Whether `path` (relative to the root) lies in a hidden directory such as `.git` or `.fallout`."
function hidden(path::AbstractString)::Bool
    return any(startswith(part, ".") for part in splitpath(dirname(path)))
end

"""
The digest of a name's definitions: the load-time items that bind or mention it without
binding anything (`using .B: f`, `K[1] = 2`), and the headers of its methods. A name that
load-time code can call (in `loaded`) also digests its methods' bodies.
"""
function name_digest(
        name::AbstractString,
        loaders::AbstractVector{Digested},
        functions::AbstractVector{Digested},
        loaded::Set{String},
    )::String
    codes = sort(
        [
            entry.digest
                for entry in loaders
                if name in entry.item.keys ||
                (isempty(entry.item.keys) && name in entry.item.mentions)
        ]
    )
    methods = [entry for entry in functions if entry.item.name == name]
    headers = sort([string(entry.item.scope, ".", entry.item.header) for entry in methods])
    bodies = sort([entry.digest for entry in methods if name in loaded])
    return sha1_text(vcat(codes, "|", headers, "|", bodies))
end

"Every name in `start` and the names reached from it through `mentions`."
function name_closure(mentions::AbstractDict, start::Set{String})::Set{String}
    grown = union(start, (get(mentions, name, Set{String}()) for name in start)...)
    if grown == start
        return start
    end
    return name_closure(mentions, grown)
end

"""
The names load-time code can reach: those bindings mention, and those the methods of a
reached name mention.
"""
function loaded_names(
        bindings::AbstractVector{Digested},
        functions::AbstractVector{Digested},
    )::Set{String}
    names = Set(entry.item.name for entry in functions)
    calls = Dict(
        name => union(
            Set{String}(),
            (entry.item.mentions for entry in functions if entry.item.name == name)...
        )
            for name in names
    )
    return name_closure(
        calls,
        union(Set{String}(), (entry.item.mentions for entry in bindings)...),
    )
end

"The directory `--code-coverage=@DIR` tracks; an error when Julia runs without it."
function coverage_root()::String
    options = Base.JLOptions()
    # fatou-ignore discouraged-function: Julia owns this option string for the whole session
    tracked = options.tracked_path == C_NULL ? "" : unsafe_string(options.tracked_path)
    return tracked_root(options.code_coverage, tracked)
end

"`tracked`, the directory coverage at `level` tracks; an error when coverage tracks no directory."
function tracked_root(level::Integer, tracked::T)::T where {T <: AbstractString}
    if level == 0 || isempty(tracked)
        error(
            "units track code by coverage: start Julia with `--code-coverage=@DIR`, DIR holding the package and its tests, ",
            "or pass `unit_cache(; root = DIR, track = :sources)` to depend on every file under DIR",
        )
    end
    return tracked
end

"The root a cache watches by default: the tracked directory under coverage, else the working directory."
function default_root(track::Symbol)::String
    if track == :coverage
        return coverage_root()
    end
    return pwd()
end

"""
    unit_cache(; track = :coverage, root, dir = ROOT/.fallout/units, project = Base.active_project(), refresh = false)

A unit cache for the code under `root`, parsed now. With `track = :coverage` (Julia started
with `--code-coverage=@ROOT`) a unit depends on the items it ran; with `track = :sources`
it depends on every `.jl` file under `root` (default: the working directory). Every unit
also depends on Julia's version and `project`'s `Project.toml`, manifest and preferences.
"""
function unit_cache(;
        track::Symbol = :coverage,
        root::AbstractString = default_root(track),
        dir::AbstractString = joinpath(root, ".fallout", "units"),
        project::AbstractString = Base.active_project(),
        refresh::Bool = false,
    )::UnitCache
    if !(track in (:coverage, :sources))
        error("`track` is `:coverage` or `:sources`, not `:", track, "`")
    end
    if !isdir(root)
        error("unit cache root `", root, "` is not a directory")
    end
    whole = realpath(root)
    if track == :coverage
        tracked = realpath(coverage_root())
        if whole != tracked && isempty(relative_path(tracked, whole))
            error(
                "unit cache root `",
                whole,
                "` lies outside the directory coverage tracks, `",
                tracked,
                "`",
            )
        end
    end
    paths = [path for path in jl_files(whole, ".") if !hidden(path)]
    items = [
        Digested(path, item, code_digest(item))
            for path in paths
            for item in source_items(read(joinpath(whole, path), String), path)
    ]
    bindings = [entry for entry in items if entry.item.kind == :binding]
    loaders = vcat(bindings, [entry for entry in items if import_item(entry.item)])
    functions = [entry for entry in items if entry.item.kind == :function]
    loaded = loaded_names(bindings, functions)
    defined = union(
        Set(name for entry in loaders for name in entry.item.mentions),
        Set(entry.item.name for entry in functions)
    )
    names = Dict(name => name_digest(name, loaders, functions, loaded) for name in defined)
    mentions = Dict(
        name => union(
            Set{String}(),
            (entry.item.mentions for entry in bindings if name in entry.item.keys)...,
            (
                entry.item.mentions
                    for entry in functions
                    if entry.item.name == name && name in loaded
            )...
        )
            for name in defined
    )
    return UnitCache(
        abspath(dir),
        whole,
        track,
        refresh,
        environment_digest(project),
        items,
        names,
        mentions,
        method_owners(whole, items),
    )
end

"Each method Julia has from a file under `root`, mapped to the item of `items` it starts in."
function method_owners(root::AbstractString, items::AbstractVector{Digested})::Dict{
        Method,
        Digested,
    }
    matches = Base._methods_by_ftype(Tuple, -1, Base.get_world_counter())
    located = [
        (match.method, relative_path(root, String(match.method.file)))
            for match in matches
            if match.method.file != :none
    ]
    return Dict(
        method => entry
            for (method, file) in located
            if !isempty(file)
            for entry in items
            if entry.path == file && entry.item.first <= method.line <= entry.item.last
    )
end

"The method instances an edge of compiled code names."
edge_targets(edge::Union{Core.CodeInstance, Core.ABIOverride})::Vector{Core.MethodInstance} = edge_targets(edge.def)
edge_targets(edge::Core.MethodInstance)::Vector{Core.MethodInstance} = [edge]
edge_targets(edge::Any)::Vector{Core.MethodInstance} = Core.MethodInstance[]

"`code` and the compiled versions chained after it."
function code_chain(code::Core.CodeInstance)::Vector{Core.CodeInstance}
    if isdefined(code, :next)
        return vcat(code, code_chain(code.next))
    end
    return [code]
end

"""
The method instances the compiled versions of `instance` call or folded into constants.
Julia keeps these edges to invalidate code, so they hold calls that leave no coverage.
"""
function compiled_callees(instance::Core.MethodInstance)::Vector{Core.MethodInstance}
    if !isdefined(instance, :cache)
        return Core.MethodInstance[]
    end
    return [
        target
            for code in code_chain(instance.cache)
            if isdefined(code, :edges)
            for edge in code.edges
            for target in edge_targets(edge)
    ]
end

"`seen`, `frontier` and every method instance reachable from `frontier` through compiled edges."
function compiled_closure(
        frontier::Set{Core.MethodInstance},
        seen::Set{Core.MethodInstance},
    )::Set{Core.MethodInstance}
    if isempty(frontier)
        return seen
    end
    grown = union(seen, frontier)
    callees = Set{Core.MethodInstance}(
        callee for instance in frontier for callee in compiled_callees(instance)
    )
    return compiled_closure(setdiff(callees, grown), grown)
end

"""
The items whose methods the compiled code of `ran` reaches. Methods defined after the cache
was made are looked up again when one of the items that ran has none.
"""
function compiled_items(cache::UnitCache, ran::AbstractVector{Digested})::Vector{Digested}
    started = Set((entry.path, entry.item.first) for entry in ran)
    owned = Set((entry.path, entry.item.first) for entry in values(cache.owners))
    owners = cache.owners
    if any(
            entry.item.kind == :function && !((entry.path, entry.item.first) in owned)
                for entry in ran
        )
        owners = method_owners(cache.root, cache.items)
    end
    roots = Set{Core.MethodInstance}(
        instance
            for (method, entry) in owners
            if (entry.path, entry.item.first) in started
            for instance in Base.specializations(method)
    )
    reached = compiled_closure(roots, Set{Core.MethodInstance}())
    return [
        owners[instance.def]
            for instance in reached
            if instance.def isa Method && haskey(owners, instance.def)
    ]
end

"A record of `ran`, the items a unit executed."
function unit_record(cache::UnitCache, ran::AbstractVector{Digested})::UnitRecord
    paths = unique(entry.path for entry in ran)
    items = Dict(
        path => sort(unique(entry.digest for entry in ran if entry.path == path))
            for path in paths
    )
    start = union(
        Set{String}(),
        (entry.item.mentions for entry in ran)...,
        Set(entry.item.name for entry in ran if entry.item.kind == :function)
    )
    return UnitRecord(
        items,
        Dict(
            name => get(cache.names, name, "")
                for name in name_closure(cache.mentions, start)
        ),
        "",
    )
end

"""
Whether the code `record` names is unchanged in `cache`'s tree. Under `:sources` the tree
holds exactly the recorded items, so an added item breaks the record too.
"""
function holds(cache::UnitCache, record::UnitRecord)::Bool
    present = Set((entry.path, entry.digest) for entry in cache.items)
    recorded = Set((path, digest) for (path, digests) in record.items for digest in digests)
    if cache.track == :sources
        return recorded == present
    end
    return issubset(recorded, present) &&
        all(get(cache.names, name, "") == digest for (name, digest) in record.names)
end

"The lines of one LCOV record that ran."
function record_lines(record::AbstractString)::Vector{CoveredLine}
    rows = split(record, '\n')
    files = [chopprefix(row, "SF:") for row in rows if startswith(row, "SF:")]
    if isempty(files)
        return CoveredLine[]
    end
    counts = [
        parse.(Int, first(split(chopprefix(row, "DA:"), ','), 2))
            for row in rows
            if startswith(row, "DA:")
    ]
    return [CoveredLine(String(only(files)), line, count) for (line, count) in counts if count > 0]
end

"Every line that ran since the coverage counters were last cleared."
function coverage_lines()::Vector{CoveredLine}
    tracefile = tempname() * ".info"
    ccall(:jl_write_coverage_data, Cvoid, (Cstring,), tracefile)
    text = read(tracefile, String)
    rm(tracefile)
    return [covered for record in split(text, "end_of_record") for covered in record_lines(record)]
end

"""
The value of `compute(config)`, the lines it ran and its time. Before Julia 1.14 these are
the lines whose count grew. From 1.14 coverage records whether a line ran, not how often: the
counters are cleared first, and the lines that ran earlier are visited again afterward, which
keeps them in the process's own coverage report. (Before 1.14, clearing detaches compiled code
from its counters.)
"""
function covered_run(compute::Any, config::Any)::Tuple{Any, Vector{CoveredLine}, Float64}
    earlier = coverage_lines()
    if VERSION < v"1.14.0-"
        timed = @timed compute(config)
        return (timed.value, setdiff(coverage_lines(), earlier), timed.time)
    end
    # COV_EXCL_START: the coverage job runs a Julia older than 1.14; the `pre` job tests this.
    ccall(:jl_clear_coverage_data, Cvoid, ())
    try
        timed = @timed compute(config)
        return (timed.value, coverage_lines(), timed.time)
    finally
        for covered in earlier
            ccall(
                :jl_coverage_visit_line,
                Cvoid,
                (Cstring, Csize_t, Cint),
                covered.file,
                sizeof(covered.file),
                covered.line,
            )
        end
    end
    # COV_EXCL_STOP
end

"""
The record of the items holding a line in `ran`. A file under the root that the cache did
not parse records the digest `unparsed`, which never holds.
"""
function ran_record(cache::UnitCache, ran::AbstractVector{CoveredLine})::UnitRecord
    located = [(relative_path(cache.root, covered.file), covered.line) for covered in ran]
    lines = [(path, line) for (path, line) in located if !isempty(path)]
    covered = [
        entry
            for entry in cache.items
            if any(
                path == entry.path && entry.item.first <= line <= entry.item.last
                for (path, line) in lines
            )
    ]
    record = unit_record(cache, vcat(covered, compiled_items(cache, covered)))
    unparsed = setdiff(Set(first.(lines)), Set(entry.path for entry in cache.items))
    if isempty(unparsed)
        return record
    end
    @warn "Fallout unit ran files its cache did not parse, so its result will not be reused" files = sort(
        collect(unparsed),
    )
    return UnitRecord(
        merge(record.items, Dict(path => ["unparsed"] for path in unparsed)),
        record.names,
        "",
    )
end

"Check that `compute` holds no captured state and, under coverage, is defined under the root."
function check_compute(compute::Any, cache::UnitCache, config::Any)::Nothing
    if fieldcount(typeof(compute)) > 0
        error(
            "a unit's function must capture nothing: pass its inputs through `config` (it holds ",
            fieldnames(typeof(compute)),
            ")",
        )
    end
    method = which(compute, (typeof(config),))
    if cache.track == :coverage && isempty(relative_path(cache.root, String(method.file)))
        error(
            "a unit's function is defined in ",
            method.file,
            ", outside the tracked root ",
            cache.root,
        )
    end
    return nothing
end

"""
The module-qualified name of `compute`. An anonymous function is an error: its generated
name shifts when unrelated code above it changes.
"""
function unit_name(compute::Any)::String
    if compute isa Function
        owner, name = parentmodule(compute), string(nameof(compute))
    else
        owner, name = parentmodule(typeof(compute)), string(nameof(typeof(compute)))
    end
    if startswith(name, "#")
        error(
            "a unit's function must be a named top-level function, not an anonymous function or `do` block",
        )
    end
    return string(owner, ".", name)
end

"""
The key of a unit: its function's name and type, its config's type and stable hash (which
skips type parameters), the environment and the tracking mode.
"""
function unit_key(cache::UnitCache, name::AbstractString, compute::Any, config::Any)::String
    configured = bytes2hex(stable_hash(config; version = 4))
    return first(
        sha1_text(
            [
                "fallout-unit-2",
                name,
                string(typeof(compute)),
                string(typeof(config)),
                configured,
                cache.environment,
                string(cache.track),
            ]
        ),
        24,
    )
end

"The name of a stored file: the first 24 hex digits of its contents' SHA-1."
stored_name(bytes::AbstractVector{UInt8})::String = first(bytes2hex(SHA.sha1(bytes)), 24)

"Whether `bytes` are the contents the name of `path` digests."
named_by(bytes::AbstractVector{UInt8}, path::AbstractString)::Bool = stored_name(bytes) ==
    first(splitext(basename(path)))

function record_toml(record::UnitRecord)::Vector{UInt8}
    buffer = IOBuffer()
    TOML.print(
        buffer,
        Dict("items" => record.items, "names" => record.names, "result" => record.result);
        sorted = true,
    )
    return take!(buffer)
end

"The record stored at `path`, or `nothing` with a warning when it does not match its name."
function stored_record(path::AbstractString)::Union{Nothing, UnitRecord}
    bytes = read(path)
    if !named_by(bytes, path)
        @warn "Fallout unit record is damaged; ignoring it" path
        return nothing
    end
    table = TOML.parse(String(bytes))
    items = Dict{String, Vector{String}}(
        file => String.(digests)
            for (file, digests) in table["items"]
    )
    return UnitRecord(items, Dict{String, String}(table["names"]), table["result"])
end

"Write `bytes` to `path` through a temporary file beside it, so readers never see half of it."
function write_whole(path::AbstractString, bytes::AbstractVector{UInt8})::Nothing
    partial, io = mktemp(dirname(path))
    write(io, bytes)
    close(io)
    chmod(partial, 0o644)
    mv(partial, path; force = true)
    return nothing
end

"The stored results under `place` whose records hold, newest first."
function holding_results(cache::UnitCache, place::AbstractString)::Vector{String}
    if cache.refresh || !isdir(place)
        return String[]
    end
    records = [
        stored_record(joinpath(place, file))
            for file in readdir(place)
            if endswith(file, ".toml")
    ]
    holding = unique(
        joinpath(place, record.result * ".jls")
            for record in records
            if !isnothing(record) && holds(cache, record)
    )
    return sort(holding; by = mtime, rev = true)
end

"The first of `paths` whose contents match its name, deserialized; `nothing` when none does."
function stored_result(paths::AbstractVector{<:AbstractString})::Union{Nothing, Some}
    for path in paths
        if isfile(path)
            bytes = read(path)
            if named_by(bytes, path)
                return Some(deserialize(IOBuffer(bytes)))
            end
        end
        @warn "Fallout unit result is missing or damaged; trying the next one" path
    end
    return nothing
end

"Run `compute(config)` and record the code it depends on."
function run_compute(compute::Any, cache::UnitCache, config::Any)::Tuple{
        Any,
        UnitRecord,
        Float64,
    }
    if cache.track == :sources
        timed = @timed compute(config)
        return (timed.value, unit_record(cache, cache.items), timed.time)
    end
    if islocked(COMPUTING)
        error(
            "units compute one at a time under coverage: run nested or threaded units in separate processes",
        )
    end
    lock(COMPUTING)
    try
        result, ran, seconds = covered_run(compute, config)
        return (result, ran_record(cache, ran), seconds)
    finally
        unlock(COMPUTING)
    end
end

"""
    unit(compute, cache, config)

The result of `compute(config)`, read from `cache` when a unit of this function, `config`
and environment stored one and the code that run executed is unchanged; otherwise
computed and stored. `compute` is a named function that captures nothing, so `config`
holds every input that matters.
"""
function unit(compute::Any, cache::UnitCache, config::Any)
    name = unit_name(compute)
    check_compute(compute, cache, config)
    place = joinpath(cache.dir, unit_key(cache, name, compute, config))
    stored = stored_result(holding_results(cache, place))
    if !isnothing(stored)
        @debug "Fallout unit reused" name
        return something(stored)
    end
    result, record, seconds = run_compute(compute, cache, config)
    buffer = IOBuffer()
    serialize(buffer, result)
    bytes = take!(buffer)
    text = record_toml(UnitRecord(record.items, record.names, stored_name(bytes)))
    mkpath(place)
    write_whole(joinpath(place, stored_name(bytes) * ".jls"), bytes)
    write_whole(joinpath(place, stored_name(text) * ".toml"), text)
    @info "Fallout unit computed" name seconds
    return result
end
