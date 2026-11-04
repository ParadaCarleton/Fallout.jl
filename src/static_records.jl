include("static_reach.jl")

using SHA: SHA

"""One function of a tracked file: where it sits and the hash of its parsed code."""
struct Definition
    file::String
    header::String
    first::Int
    last::Int
    source::Bool
    hash::String
end

"""A tracked file's functions, found by line: first lines ascending, with each function's last line and `Definition` number."""
struct FilePlaces
    firsts::Vector{Int}
    lasts::Vector{Int}
    numbers::Vector{Int}
end

"""
Where methods are: the root their files are relative to, every tracked file's functions, and
each method's file and line once found (`Revise`'s line lookup parses the file, which a walk
of tens of thousands of frames repeats for the same few thousand methods).
"""
struct Placements
    root::String
    files::Dict{String, FilePlaces}
    found::Dict{Method, Tuple{String, Int}}
end

"""What a frame reached, as `Definition` numbers rather than `Method`s so a cache can hold it."""
struct FrameRecord
    positions::Vector{Int}
    callees::Vector{String}
    unresolved::Vector{String}
    unmapped::Vector{String}
    everything::Bool
end

"""Write `expression` as nested heads and arguments, leaving out line-number nodes."""
function write_canonical(io::IO, expression::Expr)::Nothing
    print(io, '(', expression.head)
    for argument in expression.args
        if !(argument isa LineNumberNode)
            print(io, ' ')
            write_canonical(io, argument)
        end
    end
    print(io, ')')
    return nothing
end
write_canonical(io::IO, value::Any)::Nothing = show(io, value)

"""The hash of the code `text` parses to: comments, whitespace and line numbers do not reach it."""
function ast_hash(text::AbstractString)::String
    io = IOBuffer()
    write_canonical(io, Meta.parseall(String(text)))
    return bytes2hex(SHA.sha1(take!(io)))
end

"""`expression` with each testset macro call replaced by its body, so the body can be a function."""
function without_testsets(expression::Expr, macros::AbstractVector{String})::Any
    if expression.head === :macrocall
        head = first(expression.args)
        if head === Symbol("@testset") || (head isa Symbol && String(head) in string.("@", macro_name.(macros)))
            return without_testsets(last(expression.args), macros)
        end
    end
    return Expr(expression.head, Any[without_testsets(argument, macros) for argument in expression.args]...)
end
without_testsets(value::Any, ::AbstractVector{String})::Any = value

"""The `using` and `import` statements inside `expression`, which a function body cannot hold."""
function hoisted_imports(expression::Expr)::Vector{Expr}
    if expression.head in (:using, :import)
        return Expr[expression]
    end
    return reduce(vcat, (hoisted_imports(argument) for argument in expression.args); init = Expr[])
end
hoisted_imports(::Any)::Vector{Expr} = Expr[]

"""`expression` with its `using` and `import` statements replaced by `nothing`."""
function without_imports(expression::Expr)::Any
    if expression.head in (:using, :import)
        return nothing
    end
    return Expr(expression.head, Any[without_imports(argument) for argument in expression.args]...)
end
without_imports(value::Any)::Any = value

"""Return a configured macro's name before its optional prefix separator."""
macro_name(spec::AbstractString)::String = String(first(split(spec, '='; limit = 2)))

"""Return a configured macro's testset name prefix."""
function macro_prefix(spec::AbstractString)::String
    parts = split(spec, '='; limit = 2)
    if length(parts) == 2
        return String(last(parts))
    end
    return ""
end

"""Return literal names of calls to configured extra testset macros."""
function extra_testset_names(expression::Expr, macros::AbstractVector{String})::Vector{String}
    names = String[]
    if expression.head === :macrocall && first(expression.args) isa Symbol
        matching = String[entry for entry in macros if string("@", macro_name(entry)) == String(first(expression.args))]
        if !isempty(matching)
            names = String[string(macro_prefix(first(matching)), argument) for argument in expression.args if argument isa String]
        end
    end
    nested = reduce(vcat, (extra_testset_names(argument, macros) for argument in expression.args); init = String[])
    return vcat(names, nested)
end
extra_testset_names(::Any, ::AbstractVector{String})::Vector{String} = String[]

"""The `Placements` of `definitions`, numbered by their position in it."""
function placements_of(root::AbstractString, definitions::AbstractVector{Definition})::Placements
    files = Dict{String, FilePlaces}(
        file => FilePlaces(
            Int[definition.first for definition in definitions if definition.file == file],
            Int[definition.last for definition in definitions if definition.file == file],
            Int[number for (number, definition) in enumerate(definitions) if definition.file == file],
        ) for file in unique(definition.file for definition in definitions)
    )
    return Placements(realpath(root), files, Dict{Method, Tuple{String, Int}}())
end

"""Write `type` as module-qualified names and parameters, without `show`, which fails on some inferred signatures."""
function write_type(io::IO, type::DataType)::Nothing
    print(io, type.name.module, '.', type.name.name)
    if !isempty(type.parameters)
        print(io, '{')
        for parameter in type.parameters
            write_type(io, parameter)
            print(io, ',')
        end
        print(io, '}')
    end
    return nothing
end
function write_type(io::IO, type::UnionAll)::Nothing
    print(io, "all ", type.var.name, '<')
    write_type(io, type.var.lb)
    print(io, '<')
    write_type(io, type.var.ub)
    print(io, ' ')
    write_type(io, type.body)
    return nothing
end
function write_type(io::IO, type::Union)::Nothing
    print(io, "union{")
    write_type(io, type.a)
    print(io, ',')
    write_type(io, type.b)
    print(io, '}')
    return nothing
end
function write_type(io::IO, type::TypeVar)::Nothing
    print(io, "var ", type.name)
    return nothing
end
function write_type(io::IO, type::Core.TypeofVararg)::Nothing
    print(io, "vararg{")
    if isdefined(type, :T)
        write_type(io, type.T)
    end
    print(io, ',')
    if isdefined(type, :N)
        write_type(io, type.N)
    end
    print(io, '}')
    return nothing
end
write_type(io::IO, value::Any)::Nothing = print(io, typeof(value), ':', value)

"""A key for the signature `type` that names its types structurally."""
function type_key(type::Type)::String
    io = IOBuffer()
    write_type(io, type)
    return String(take!(io))
end

"""A tracked file's item that is neither a function nor a testset (a struct, constant, macro, include, a call at top level), kept by the hash of its code: its `name` (empty for an item that defines none) and the identifiers it `mentions`, one entry per occurrence."""
struct OtherItem
    file::String
    name::String
    hash::String
    mentions::Vector{String}
end

"""Matches an identifier, with unicode letters, digits and the trailing `!` Julia names allow, that no `@` or letter precedes (a macro's name is not a function's)."""
const IDENTIFIER = r"(?<![@\p{L}\p{N}_!])[\p{L}_][\p{L}\p{N}_!]*"

"""The identifiers in `text`, one entry per occurrence, comments and strings included (a superset of what the code mentions)."""
mentioned_identifiers(text::AbstractString)::Vector{String} = String[found.match for found in eachmatch(IDENTIFIER, text)]

"""The identifiers an item that defines no name mentions, for the names its edits change: those of an item that calls a macro (a rule, an `@eval` loop), none for the rest (`include` lines, a call of `main`)."""
function other_mentions(text::AbstractString)::Vector{String}
    if occursin(r"@(?!__)", text)
        return mentioned_identifiers(text)
    end
    return String[]
end

"""
    definition_identities(definitions)

One identity per definition that other definitions' edits do not change: its file and header, and
its number among the definitions with that file and header (a header can repeat).
"""
function definition_identities(definitions::AbstractVector{Definition})::Vector{String}
    bases = String["$(definition.file) $(definition.header)" for definition in definitions]
    counts = Dict{String, Int}(base => 0 for base in bases)
    identities = similar(bases)
    for (slot, base) in zip(eachindex(identities), bases)
        counts[base] += 1
        identities[slot] = string(base, " #", counts[base])
    end
    return identities
end

"""Return the current source line of a method."""
method_line(method::Method)::Int = Int(method.line)

"""The path of the file defining `method` relative to the root of `placements` (symlinks resolved), empty for a method with no file."""
function tracked_path(placements::Placements, method::Method)::String
    return first(method_location(placements, method))
end

"""The file `tracked_path` names and the `method_line` of `method`, found once per method."""
function method_location(placements::Placements, method::Method)::Tuple{String, Int}
    if haskey(placements.found, method)
        return placements.found[method]
    end
    file = String(method.file)
    path = ""
    if isfile(file)
        path = relpath(realpath(file), placements.root)
    end
    line = 0
    if haskey(placements.files, path)
        line = method_line(method)
    end
    location = (path, line)
    placements.found[method] = location
    return location
end

"""
    place(placements, method)

The `Definition` number of the tracked function holding `method`'s first line; 0 for a method
in an untracked file, -1 for one in a tracked file that no function of it holds (a method a
macro or a short-form definition made).
"""
function place(placements::Placements, method::Method)::Int
    file, line = method_location(placements, method)
    if !haskey(placements.files, file)
        return 0
    end
    places = placements.files[file]
    index = searchsortedlast(places.firsts, line)
    if index == 0 || places.lasts[index] < line
        return -1
    end
    return places.numbers[index]
end

"""A frame's `FrameRecord`: the tracked functions its methods are and the label of each method no function holds."""
function frame_record(placements::Placements, edges::FrameEdges)::FrameRecord
    numbers = Int[place(placements, method) for method in edges.methods]
    unmapped = String[string(method_location(placements, method)[1], ':', method_location(placements, method)[2]) for (method, number) in zip(edges.methods, numbers) if number == -1]
    return FrameRecord(
        unique(filter(>(0), numbers)),
        String[type_key(callee) for callee in edges.callees],
        edges.unresolved,
        unique(unmapped),
        edges.everything,
    )
end

"""Whether item `index` belongs to part `part` of `parts`: every `parts`-th item from the `part`-th, so neighboring testsets of one cost spread over the parts."""
in_part(index::Integer, part::Integer, parts::Integer)::Bool = mod(index - 1, parts) == part - 1
