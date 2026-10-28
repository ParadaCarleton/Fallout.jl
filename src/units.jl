# ---------------------------------------------------------------------------------------
# Units: cached pieces of a long test, reused while the code they ran is unchanged
# ---------------------------------------------------------------------------------------

"An item of the tree a unit cache watches, with its file and the digest of its code."
struct Digested
    path::String
    item::Item
    digest::String
end

"""
The code a unit's result depends on: for each file, the digests of the items it ran, and
for each name those items mention, the digest of that name's definitions (`""` when none).
"""
struct UnitRecord
    items::Dict{String, Vector{String}}
    names::Dict{String, String}
end

"""
    UnitCache

Where units store results (`dir`) and the tree whose code they depend on (`root`), parsed
when the cache was made. `track` is `:coverage` (a unit depends on the code it ran) or
`:sources` (on every file under `root`). `environment` digests Julia's version, the active
project, its manifest and its preferences. `refresh` recomputes every unit.
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
end

"One line of an LCOV tracefile: its file relative to the root, its number and its count."
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

"The digest of an item's code tokens: blanks and comments do not count, and `text` holds no docstring."
item_digest(item::Item)::String = sha1_text(code_tokens([item.text]))

"The text of `path`, or empty when there is no such file."
function file_text(path::Union{Nothing, AbstractString})::String
    if isnothing(path) || !isfile(path)
        return ""
    end
    return read(path, String)
end

"The digest of Julia's version and `project`'s `Project.toml`, manifest and preferences."
function environment_digest(project::AbstractString)::String
    files = [
        project,
        Base.project_file_manifest_path(project),
        joinpath(dirname(project), "LocalPreferences.toml"),
    ]
    return sha1_text(vcat(string(VERSION), file_text.(files)))
end

"Whether `path` (relative to the root) lies in a hidden directory such as `.git` or `.fallout`."
function hidden(path::AbstractString)::Bool
    return any(startswith(part, ".") for part in splitpath(dirname(path)))
end

"The digest of a name's definitions: the code of its bindings and the headers of its methods."
function name_digest(
    name::AbstractString,
    bindings::AbstractVector{Digested},
    functions::AbstractVector{Digested},
)::String
    codes = sort([entry.digest for entry in bindings if name in entry.item.keys])
    headers = sort([entry.item.header for entry in functions if entry.item.name == name])
    return sha1_text(vcat(codes, "|", headers))
end

"The directory `--code-coverage=@DIR` tracks; an error when Julia runs without it."
function coverage_root()::String
    options = Base.JLOptions()
    # fatou-ignore discouraged-function: Julia owns this option string for the whole session
    tracked = options.tracked_path == C_NULL ? "" : unsafe_string(options.tracked_path)
    if options.code_coverage == 0 || isempty(tracked)
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
    if track == :coverage
        coverage_root()
    end
    if !isdir(root)
        error("unit cache root `", root, "` is not a directory")
    end
    whole = realpath(root)
    paths = [path for path in jl_files(whole, ".") if !hidden(path)]
    items = [
        Digested(path, item, item_digest(item))
        for path in paths
        for item in source_items(read(joinpath(whole, path), String), path)
    ]
    bindings = [entry for entry in items if entry.item.kind == :binding]
    functions = [entry for entry in items if entry.item.kind == :function]
    defined = union(
        Set(key for entry in bindings for key in entry.item.keys),
        Set(entry.item.name for entry in functions)
    )
    names = Dict(name => name_digest(name, bindings, functions) for name in defined)
    mentions = Dict(
        name => union(
            Set{String}(),
            (entry.item.mentions for entry in bindings if name in entry.item.keys)...
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
    )
end

"Every name reachable from `start` through the names that bindings mention."
function name_closure(cache::UnitCache, start::Set{String})::Set{String}
    grown = union(start, (get(cache.mentions, name, Set{String}()) for name in start)...)
    if grown == start
        return start
    end
    return name_closure(cache, grown)
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
        Dict(name => get(cache.names, name, "") for name in name_closure(cache, start))
    )
end

"Whether the code `record` names is unchanged in `cache`'s tree."
function holds(cache::UnitCache, record::UnitRecord)::Bool
    present = Set((entry.path, entry.digest) for entry in cache.items)
    items_hold = all(
        (path, digest) in present
        for (path, digests) in record.items
        for digest in digests
    )
    return items_hold &&
        all(get(cache.names, name, "") == digest for (name, digest) in record.names)
end

"Every line of one LCOV record whose file lies under `root`."
function record_counts(record::AbstractString, root::AbstractString)::Vector{CoveredLine}
    rows = split(record, '\n')
    files = [chopprefix(row, "SF:") for row in rows if startswith(row, "SF:")]
    if isempty(files)
        return CoveredLine[]
    end
    file = relative_path(root, String(only(files)))
    counts = [
        parse.(Int, first(split(chopprefix(row, "DA:"), ','), 2))
        for row in rows
        if startswith(row, "DA:")
    ]
    return [CoveredLine(file, line, count) for (line, count) in counts if !isempty(file)]
end

"The execution count of every covered line under `root` so far, keyed by `(file, line)`."
function coverage_counts(root::AbstractString)::Dict{Tuple{String, Int}, Int}
    tracefile = tempname() * ".info"
    ccall(:jl_write_coverage_data, Cvoid, (Cstring,), tracefile)
    text = read(tracefile, String)
    rm(tracefile)
    return Dict(
        (covered.file, covered.line) => covered.count
        for record in split(text, "end_of_record")
        for covered in record_counts(record, root)
    )
end

"""
The record of the items holding a line whose count grew from `before` to `after`. A file
the cache did not parse records the digest `unparsed`, which never holds.
"""
function ran_record(cache::UnitCache, before::AbstractDict, after::AbstractDict)::UnitRecord
    lines = [key for (key, count) in after if count > get(before, key, 0)]
    ran = [
        entry
        for entry in cache.items
        if any(
            path == entry.path && entry.item.first <= line <= entry.item.last
            for (path, line) in lines
        )
    ]
    record = unit_record(cache, ran)
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

"The key of a unit: its function's name, its config's stable hash, the environment and the tracking mode."
function unit_key(cache::UnitCache, name::AbstractString, config::Any)::String
    configured = bytes2hex(stable_hash(config; version = 4))
    return first(
        sha1_text([
            "fallout-unit-1",
            name,
            configured,
            cache.environment,
            string(cache.track),
        ]),
        24,
    )
end

function record_toml(record::UnitRecord)::String
    buffer = IOBuffer()
    TOML.print(
        buffer,
        Dict("items" => record.items, "names" => record.names);
        sorted = true,
    )
    return String(take!(buffer))
end

function read_record(path::AbstractString)::UnitRecord
    table = TOML.parsefile(path)
    items = Dict{String, Vector{String}}(
        file => String.(digests)
        for (file, digests) in table["items"]
    )
    return UnitRecord(items, Dict{String, String}(table["names"]))
end

"Write `contents` to `path` through a temporary file, so readers never see half of it."
function write_whole(path::AbstractString, contents::Any)::Nothing
    partial = string(path, ".", getpid(), ".partial")
    if contents isa AbstractString
        write(partial, contents)
    else
        serialize(partial, contents)
    end
    mv(partial, path; force = true)
    return nothing
end

"The stored results under `place` whose records hold, newest first."
function holding_results(cache::UnitCache, place::AbstractString)::Vector{String}
    if cache.refresh || !isdir(place)
        return String[]
    end
    records = [joinpath(place, file) for file in readdir(place) if endswith(file, ".toml")]
    holding = [
        chopsuffix(record, ".toml") * ".jls"
        for record in records
        if holds(cache, read_record(record))
    ]
    return sort(holding; by = mtime, rev = true)
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
        before = coverage_counts(cache.root)
        timed = @timed compute(config)
        return (
            timed.value,
            ran_record(cache, before, coverage_counts(cache.root)),
            timed.time,
        )
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
    place = joinpath(cache.dir, unit_key(cache, name, config))
    holding = holding_results(cache, place)
    if !isempty(holding)
        @debug "Fallout unit reused" name
        return deserialize(first(holding))
    end
    result, record, seconds = run_compute(compute, cache, config)
    text = record_toml(record)
    stem = joinpath(place, first(sha1_text([text]), 24))
    mkpath(place)
    write_whole(stem * ".jls", result)
    write_whole(stem * ".toml", text)
    @info "Fallout unit computed" name seconds
    return result
end
