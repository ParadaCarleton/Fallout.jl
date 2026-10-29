using Test
using Fallout
using Salsa: Salsa
const StaticRecords = Fallout.StaticMap

"""Read frame records produced by Salsa reach queries for unit assertions."""
function test_walk(
        records::Dict{String, StaticRecords.FrameRecord}, mode::StaticRecords.WalkMode,
        scope::StaticRecords.Scope, placements::StaticRecords.Placements,
        seeds::AbstractVector{Pair{String, Type}},
    )::Dict{String, StaticRecords.FrameRecord}
    storage = Salsa.DefaultStorage()
    context = StaticRecords.QueryContext(mode, scope, placements, Dict{String, Type}(), Threads.Atomic{Int}(0), Threads.Atomic{Int}(0))
    runtime = Salsa.Runtime{typeof(context), Salsa.DefaultStorage}(context, storage)
    StaticRecords.set_method_inventory_hash!(runtime, "unit")
    for path in keys(placements.files)
        StaticRecords.set_source_code_hash!(runtime, path, "unit")
    end
    for (name, _) in seeds
        StaticRecords.set_testset_code_hash!(runtime, name, "unit")
    end
    for (name, signature) in seeds
        StaticRecords.testset_reach(runtime, name, signature)
    end
    _, derived = Salsa.Inspect.all_inputs_and_derived_vals(storage)
    for (key, record) in derived
        if key isa Salsa.DerivedKey{typeof(StaticRecords.reached_frame)}
            records[StaticRecords.type_key(only(key.args))] = first(record)
        end
    end
    for (name, signature) in seeds
        records[name] = records[StaticRecords.type_key(signature)]
    end
    return records
end

"""Find frame keys reachable through recorded callees from seed names."""
function test_reachable_keys(records::AbstractDict{String, StaticRecords.FrameRecord}, seeds::AbstractVector{String})::Set{String}
    seen = Set{String}(seeds)
    pending = collect(seen)
    while !isempty(pending)
        for callee in records[pop!(pending)].callees
            if !(callee in seen)
                seen = union(seen, Set{String}([callee]))
                pending = vcat(pending, callee)
            end
        end
    end
    return seen
end

"""A module outside the walk's scope that owns a function the scope adds a method to."""
module ToyOwner
    @noinline owned(value::Any) = value
    @noinline other(value::Any) = Base.donotdelete(value)
    @noinline rule(::Any, value::Any) = value
    @noinline pair(first::Any, second::Any) = (first, second)
    @noinline keyed(value::Any; scale::Integer = 1) = (value, scale)
    @noinline other_keyed(value::Any; scale::Integer = 1) = (value, scale)
end

module StaticToy
    import ..ToyOwner
    """A one-line callee the optimizer keeps as a call, so the walk must follow it."""
    @noinline helper(value::T) where {T <: Integer} = value + 1

    @noinline function inner(value::T) where {T <: Integer}
        return helper(value) * 2
    end

    function outer(value::T) where {T <: Integer}
        return inner(value) + 1
    end

    function lonely(value::T) where {T <: Integer}
        return value
    end

    function dynamic(callee::Any, value::T) where {T <: Integer}
        return callee(value)
    end

    @inline function inlined(value::T) where {T <: Integer}
        return value * 3
    end

    function outer_of_inline(value::T) where {T <: Integer}
        return inlined(value) + 1
    end

    const no_file_function = Core.eval(@__MODULE__, Meta.parse("no_file(value::Integer) = value + 5"))

    function calls_no_file(value::T) where {T <: Integer}
        return no_file_function(value) + 1
    end

    function abstract_call(value::Any)
        return inner(value)
    end

    function latest(callee::Any, value::T) where {T <: Integer}
        return Base.invokelatest(callee, value)
    end

    """A callable struct whose type parameter a caller with abstract arguments cannot know."""
    struct Scaler{T}
        factor::T
    end

    (scaler::Scaler)(value::Integer) = helper(value) * scaler.factor

    """Builds a `Scaler` from an argument of unknown type and hands it back uncalled."""
    builds_scaler(factor::Any) = Scaler(factor)

    """Calls a `Scaler` of either element type read from a holder of unknown type."""
    calls_either(holder::Any, value::Integer) = (holder.scaler::Union{Scaler{Int}, Scaler{Float32}})(value)

    """A method of a Base function on a scope type, which only Base code would call."""
    Base.length(::Scaler) = helper(1)

    """A method of a Base function on the type of a scope type, named only through a bound."""
    Base.ndims(::Type{<:Scaler}) = helper(2)

    """A constructor method of a Base type on a scope type, which only Base code would call."""
    Base.IndexStyle(::Type{<:Scaler}) = IndexLinear()

    """Hands a `Scaler` to outside code and calls nothing on it."""
    holds_scaler(factor::Integer) = ToyOwner.other(Scaler(factor))

    """Builds a `Scaler` and calls it, handing it to no outside code."""
    calls_scaler(factor::Integer) = Scaler(factor)(1)

    """A constant inference folds into its caller, leaving no call in the optimized IR."""
    answer() = 42

    """Adds the folded constant."""
    uses_answer(value::Integer) = value + answer()

    """A scope method of an outside function whose signature names no scope type."""
    ToyOwner.owned(::AbstractChar) = helper(5)

    """Calls the outside function on a type the scope's method does not take."""
    calls_owned(value::Integer) = ToyOwner.owned(value)

    """A struct whose own constructor names its parameter."""
    struct Tagged{E}
        value::Int
        Tagged{E}(value::Integer) where {E} = new{E}(helper(value))
    end

    """Builds a `Tagged` whose parameter is known only at run time."""
    builds_tagged(element::Type, value::Integer) = Tagged{element}(value)

    """Hands a `Scaler` to the outside module's own code."""
    passes_to_owner(factor::Integer) = ToyOwner.other(Scaler(factor))

    """A scope method of an outside function on a `Tagged` and `Scaler`s, as `logpdf(::LatentLikelihood, ::AbstractVector{<:Observation})`."""
    ToyOwner.pair(::Tagged, scalers::AbstractVector{<:Scaler}) = lonely(length(scalers))

    """Hands `Scaler`s, and no `Tagged`, to outside code."""
    hands_scalers(factor::Integer) = ToyOwner.other([Scaler(factor)])

    """Hands a `Tagged` to outside code."""
    hands_tagged(value::Integer) = ToyOwner.other(Tagged{Int}(value))

    """A value a keyword constructor takes, as `Candidate(position, party::Party; quality)` takes a `Party`."""
    struct Token end

    """A struct built by a keyword constructor."""
    struct Keyed
        value::Int
    end

    Keyed(::Token; scale::Integer = 1) = Keyed(lonely(scale))

    """Hands a `Token` to outside code and builds no `Keyed`."""
    hands_token() = ToyOwner.other(Token())

    """A keyword sorter of an outside function, defined in the scope."""
    Core.kwcall(::NamedTuple, ::typeof(ToyOwner.keyed), value::Integer) = lonely(value)

    """Calls a different outside function with a keyword."""
    calls_other_keyed(value::Integer) = ToyOwner.other_keyed(value; scale = 2)

    """A flag inference folds to false."""
    flag() = false

    """Calls `lonely` only where the flag is set: a branch inference finds dead."""
    function gated(value::Integer)
        if flag()
            return lonely(value)
        end
        return value
    end

    """`gated`'s dead branch inside a callee the optimizer inlines."""
    @inline function inlined_gate(value::Integer)
        if flag()
            return lonely(value)
        end
        return value
    end

    """Calls the inlined gate, so only the debug info names it."""
    calls_inlined_gate(value::Integer) = inlined_gate(value) + 1

    """A callable held deep in a value's type."""
    struct Hook end

    (::Hook)(value::Integer) = helper(value)

    """Hands a `Hook` held five parameters deep to outside code and calls nothing on it."""
    holds_hook(value::Integer) = ToyOwner.other((Some(Some(Some(Some(Hook())))), value))

    """An outside package's rule for `lonely`, which that package runs where `lonely` runs."""
    ToyOwner.rule(::typeof(lonely), value::Integer) = helper(value)

    """An outside rule for `lonely` that also names `Scaler`: it runs where `lonely` runs."""
    ToyOwner.rule(::typeof(lonely), scaler::Scaler) = lonely(scaler.factor)

    """Runs `lonely` and hands nothing to outside code."""
    runs_lonely(value::Integer) = lonely(value) + 1

    """Calls `lonely` through `invokelatest`, which hides the call from inference."""
    latest_lonely(value::Integer) = Base.invokelatest(lonely, value)

    """A function with a keyword."""
    kw_target(value::Integer; scale::Integer = 1) = lonely(value) * scale

    """A keyword call of a known function at an unknown argument type."""
    kw_known(value::Any) = kw_target(value; scale = 2)

    """A keyword call of a function known only at run time."""
    kw_unknown(callee::Any, value::Integer) = callee(value; scale = 2)

    """A splatted keyword call of a function known only at run time, as `open(f, args...; keywords...)` calls its callback."""
    splat_kw_unknown(callee::Any, items::Tuple) = callee(items...; scale = 2)

    """A splatted keyword call of a known function."""
    splat_kw_known(items::Tuple) = kw_target(items...; scale = 2)

    """A runner closure that calls `property`, defined after it, so a box holds `property`; the runner goes to outside code as `@check` hands its own. `property` takes an `Int` so the call it makes resolves."""
    function hands_boxed_runner(value::Integer)
        runner = () -> property(value)
        property(argument::Int) = lonely(argument)
        return ToyOwner.other(runner)
    end

    """A callable that calls `lonely`, which no toy frame reaches through `ToyOwner.owned`."""
    struct Probe end

    (::Probe)(value::Integer) = lonely(value)

    """Build a named tuple whose contents include a callable value."""
    function builds_from_pairs(probe::Probe, value::Integer)
        defaults = (; scale = value, probe = probe)
        built = (; (name => item for (name, item) in pairs(defaults))...)
        return length(built)
    end

    """Builds a named tuple from a generator whose function calls `lonely`."""
    function builds_with_work(value::Integer)
        built = (; (name => lonely(value) for name in (:a, :b))...)
        return length(built)
    end

    """The branch of `folds_on_value` that inference folds to a constant when its argument is `Nothing`."""
    folds_on_value(::Nothing)::UInt = UInt(0)

    """The branch of `folds_on_value` that runs on an integer."""
    function folds_on_value(value::Integer)::UInt
        return UInt(value)
    end

    """Calls `folds_on_value` on a union, as `log_pricing_census` calls `store_identity` on a memo that is `Nothing` or a tuple."""
    function splits_on_union(value::Union{Nothing, Int})::UInt
        return folds_on_value(value) + UInt(1)
    end

    """Calls `lonely`."""
    inspected(value::Integer) = lonely(value)

    """Infer `inspected`'s return type without calling it."""
    infers_inspected(argument_types::DataType) = Core.Compiler.return_type(inspected, argument_types)

    """A generator whose function calls a captured closure that calls `lonely`."""
    function calls_captured_closure(value::Integer)
        inner(argument) = lonely(argument)
        outer(argument) = inner(argument)
        return length([outer(item) for item in (value, value)])
    end

    """A holder whose type parameters a caller with abstract arguments cannot know, and no outside rule names."""
    struct Held{A, B, C}
        first::A
        second::B
        third::C
    end

    """
    Closures capture several values, including one with an abstract type. Their captured types
    can widen, so the walk follows their creation types.
    """
    function calls_chain_at_abstract_capture(holder::Held, items::AbstractVector, level::Real)
        winners = Vector{Float32}(undef, 4)
        solved = falses(4)
        function winner_for(set)
            if !solved[set + 1]
                winners[set + 1] = lonely(set + holder.first)
                solved[set + 1] = true
            end
            return winners[set + 1]
        end
        value_at(set, item) = winner_for(set) + item + level + holder.second
        return length([value_at(set, item) for set in 1:2, item in items])
    end
end

"""A test module whose imports postdate the walk's world, as a build's test module does."""
module ImportingToy end

"""
Import `StaticToy.lonely` into `ImportingToy`, define a dynamic caller of it there, then walk the
caller in the world this call started in, before the import: the order a build runs in.
"""
function walk_after_import(placements::StaticRecords.Placements)::Set{Int}
    Core.eval(ImportingToy, :(using ..StaticToy: lonely))
    Core.eval(ImportingToy, :(calls_imported(value::Any) = lonely(value)))
    caller = Base.invokelatest(getglobal, ImportingToy, :calls_imported)
    scope = StaticRecords.Scope([StaticToy, ImportingToy], String[])
    seeds = Pair{String, Type}["caller" => Tuple{typeof(caller), Any}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.FollowKnown(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["caller"])
    return Set(number for key in reached for number in records[key].positions)
end

"""Placements whose tracked functions are `tracked` (in file order), each three lines from its first, numbered in order."""
function method_placements(tracked::AbstractVector{Method})::StaticRecords.Placements
    definitions = [
        StaticRecords.Definition(basename(String(method.file)), string(method.name), Int(method.line), Int(method.line) + 2, true, "")
            for method in tracked
    ]
    return StaticRecords.placements_of(dirname(String(first(tracked).file)), definitions)
end

"""The toy functions as tracked definitions, in order, with the placements of the methods in this file."""
function toy_placements()::Tuple{Vector{Symbol}, StaticRecords.Placements}
    names = [:helper, :inner, :outer, :lonely, :dynamic, :inlined, :outer_of_inline, :calls_no_file, :abstract_call, :latest]
    methods_of = [only(methods(getglobal(StaticToy, name))) for name in names]
    root = dirname(String(first(methods_of).file))
    definitions = [
        StaticRecords.Definition(basename(String(method.file)), string(name), Int(method.line), Int(method.line) + 2, true, "")
            for (name, method) in zip(names, methods_of)
    ]
    return names, StaticRecords.placements_of(root, definitions)
end

@testset "static map: a walk reaches the functions a call chain runs and no others" begin
    names, placements = toy_placements()
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["outer" => Tuple{typeof(StaticToy.outer), Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.DropUnresolved(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["outer"])
    numbers = Set(number for key in reached for number in records[key].positions)
    @test numbers == Set(findall(in((:helper, :inner, :outer)), names))
end

# A call the compiler cannot resolve, a dynamic one or one through invokelatest, is an unresolved site.
@testset "static map: a call the compiler cannot resolve is dropped and counted, or reaches all source" begin
    _, placements = toy_placements()
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["dynamic" => Tuple{typeof(StaticToy.dynamic), Any, Int}, "latest" => Tuple{typeof(StaticToy.latest), Any, Int}]
    dropped = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.DropUnresolved(), scope, placements, seeds)
    followed = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.FollowUnresolved(), scope, placements, seeds)
    for name in first.(seeds)
        @test !isempty(dropped[name].unresolved)
        @test !dropped[name].everything
        @test followed[name].everything
    end
end

@testset "static map: a call with abstract argument types is dropped, or followed to the methods that can match" begin
    names, placements = toy_placements()
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["caller" => Tuple{typeof(StaticToy.abstract_call), Any}]
    dropped = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.DropUnresolved(), scope, placements, seeds)
    @test Set(dropped["caller"].positions) == Set(findall(==(:abstract_call), names))
    followed = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.FollowKnown(), scope, placements, seeds)
    @test Set(followed["caller"].positions) == Set(findall(in((:abstract_call, :inner)), names))
    @test !followed["caller"].everything
end

@testset "static map: a callable struct built with unknown type parameters reaches its call method" begin
    call_method = only(methods(StaticToy.Scaler(1)))
    tracked = [only(methods(StaticToy.helper)), call_method]
    placements = method_placements(tracked)
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["builder" => Tuple{typeof(StaticToy.builds_scaler), Any}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.FollowKnown(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["builder"])
    @test Set(number for key in reached for number in records[key].positions) == Set([1, 2])
end

@testset "static map: a call to a value that is one of several scope types follows the call method of each" begin
    call_method = only(methods(StaticToy.Scaler(1)))
    placements = method_placements([only(methods(StaticToy.helper)), call_method])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["caller" => Tuple{typeof(StaticToy.calls_either), Any, Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.FollowKnown(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["caller"])
    @test Set(number for key in reached for number in records[key].positions) == Set([1, 2])
    @test isempty(records["caller"].unresolved)
end

@testset "static map: a frame handing a scope type to outside code reaches the scope methods of outside functions on it" begin
    length_method = which(Base.length, (StaticToy.Scaler{Int},))
    placements = method_placements([only(methods(StaticToy.helper)), length_method])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["holder" => Tuple{typeof(StaticToy.holds_scaler), Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.FollowKnown(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["holder"])
    @test Set(number for key in reached for number in records[key].positions) == Set([1, 2])
end

@testset "static map: an outside rule for a scope function is not reached where only another scope type it names goes to outside code" begin
    placements = method_placements([which(ToyOwner.rule, (typeof(StaticToy.lonely), StaticToy.Scaler{Int}))])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["holder" => Tuple{typeof(StaticToy.holds_scaler), Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.FollowKnown(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["holder"])
    @test isempty(Set(number for key in reached for number in records[key].positions))
end

@testset "static map: a scope type a frame only holds or calls reaches no scope method of an outside function" begin
    placements = method_placements([which(Base.length, (StaticToy.Scaler{Int},))])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["caller" => Tuple{typeof(StaticToy.calls_scaler), Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.FollowKnown(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["caller"])
    @test isempty(Set(number for key in reached for number in records[key].positions))
end

@testset "static map: a rule an outside package defines for a function is reached where that function runs" begin
    placements = method_placements([only(methods(StaticToy.helper)), which(ToyOwner.rule, (typeof(StaticToy.lonely), Int))])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["caller" => Tuple{typeof(StaticToy.runs_lonely), Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.DropUnresolved(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["caller"])
    @test Set(number for key in reached for number in records[key].positions) == Set([1, 2])
end

@testset "static map: a known function called through invokelatest is reached" begin
    placements = method_placements([only(methods(StaticToy.lonely))])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["caller" => Tuple{typeof(StaticToy.latest_lonely), Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.DropUnresolved(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["caller"])
    @test Set(number for key in reached for number in records[key].positions) == Set([1])
end

@testset "static map: a scope method of an outside function is reached where a scope type it takes directly goes to outside code, not one its parameters name" begin
    placements = method_placements([only(methods(StaticToy.lonely))])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["scalers" => Tuple{typeof(StaticToy.hands_scalers), Int}, "tagged" => Tuple{typeof(StaticToy.hands_tagged), Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.FollowKnown(), scope, placements, seeds)
    @test isempty(Set(number for key in test_reachable_keys(records, ["scalers"]) for number in records[key].positions))
    @test Set(number for key in test_reachable_keys(records, ["tagged"]) for number in records[key].positions) == Set([1])
end

@testset "static map: a keyword constructor is not reached where only a value its positional arguments take goes to outside code" begin
    placements = method_placements([only(methods(StaticToy.lonely))])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["token" => Tuple{typeof(StaticToy.hands_token)}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.FollowKnown(), scope, placements, seeds)
    @test isempty(Set(number for key in test_reachable_keys(records, ["token"]) for number in records[key].positions))
end

@testset "static map: a keyword sorter of an outside function is not reached by a keyword call of another function" begin
    placements = method_placements([only(methods(StaticToy.lonely))])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["other" => Tuple{typeof(StaticToy.calls_other_keyed), Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.FollowKnown(), scope, placements, seeds)
    @test isempty(Set(number for key in test_reachable_keys(records, ["other"]) for number in records[key].positions))
end

@testset "static map: a keyword call is followed only when its function is known" begin
    # `lonely`, not `helper`: every toy frame reaches `helper` through `ToyOwner.owned`, which
    # names no scope type and whose owner shares the toys' root module.
    placements = method_placements([only(methods(StaticToy.lonely))])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["known" => Tuple{typeof(StaticToy.kw_known), Any}, "unknown" => Tuple{typeof(StaticToy.kw_unknown), Any, Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.FollowKnown(), scope, placements, seeds)
    @test Set(number for key in test_reachable_keys(records, ["known"]) for number in records[key].positions) == Set([1])
    @test isempty(Set(number for key in test_reachable_keys(records, ["unknown"]) for number in records[key].positions))
end

@testset "static map: a splatted keyword call is followed to its own function, and to none when that is known only at run time" begin
    placements = method_placements([only(methods(StaticToy.lonely))])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["known" => Tuple{typeof(StaticToy.splat_kw_known), Tuple}, "unknown" => Tuple{typeof(StaticToy.splat_kw_unknown), Any, Tuple}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.FollowKnown(), scope, placements, seeds)
    @test Set(number for key in test_reachable_keys(records, ["known"]) for number in records[key].positions) == Set([1])
    @test isempty(Set(number for key in test_reachable_keys(records, ["unknown"]) for number in records[key].positions))
end

@testset "static map: a scope method of an outside function on a bounded type parameter is reached too" begin
    ndims_method = which(Base.ndims, (Type{StaticToy.Scaler{Int}},))
    placements = method_placements([only(methods(StaticToy.helper)), ndims_method])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["holder" => Tuple{typeof(StaticToy.holds_scaler), Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.FollowKnown(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["holder"])
    @test Set(number for key in reached for number in records[key].positions) == Set([1, 2])
end

@testset "static map: a call inference folds to a constant still reaches its function" begin
    placements = method_placements([only(methods(StaticToy.answer))])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["caller" => Tuple{typeof(StaticToy.uses_answer), Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.DropUnresolved(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["caller"])
    @test Set(number for key in reached for number in records[key].positions) == Set([1])
end

@testset "static map: a call in a branch inference finds dead still reaches its function" begin
    placements = method_placements([only(methods(StaticToy.lonely))])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["caller" => Tuple{typeof(StaticToy.gated), Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.DropUnresolved(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["caller"])
    @test Set(number for key in reached for number in records[key].positions) == Set([1])
end

@testset "static map: a dead branch of a callee the optimizer inlined still reaches its function" begin
    placements = method_placements([only(methods(StaticToy.lonely))])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["caller" => Tuple{typeof(StaticToy.calls_inlined_gate), Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.DropUnresolved(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["caller"])
    @test Set(number for key in reached for number in records[key].positions) == Set([1])
end

@testset "static map: a callable scope type deep in the parameters of a value is walked" begin
    placements = method_placements([only(methods(StaticToy.helper))])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["caller" => Tuple{typeof(StaticToy.holds_hook), Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.DropUnresolved(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["caller"])
    @test Set(number for key in reached for number in records[key].positions) == Set([1])
end

@testset "static map: a callable stored in a captured variable a closure reads is walked where the closure runs" begin
    placements = method_placements([only(methods(StaticToy.lonely))])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["caller" => Tuple{typeof(StaticToy.hands_boxed_runner), Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.DropUnresolved(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["caller"])
    @test Set(number for key in reached for number in records[key].positions) == Set([1])
end

@testset "static map: a container a Base function builds from a value holding a callable does not reach that callable" begin
    placements = method_placements([only(methods(StaticToy.lonely))])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["caller" => Tuple{typeof(StaticToy.builds_from_pairs), StaticToy.Probe, Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.DropUnresolved(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["caller"])
    @test isempty(Set(number for key in reached for number in records[key].positions))
end

@testset "static map: the function a Base container builder is handed is walked" begin
    placements = method_placements([only(methods(StaticToy.lonely))])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["caller" => Tuple{typeof(StaticToy.builds_with_work), Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.DropUnresolved(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["caller"])
    @test Set(number for key in reached for number in records[key].positions) == Set([1])
end

@testset "static map: a function handed to a Base type inspector is not called" begin
    placements = method_placements([only(methods(StaticToy.lonely))])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["caller" => Tuple{typeof(StaticToy.infers_inspected), DataType}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.DropUnresolved(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["caller"])
    @test isempty(Set(number for key in reached for number in records[key].positions))
end

@testset "static map: a call the optimizer folds on one branch of a union argument still reaches that branch's method" begin
    placements = method_placements([first(sort(collect(methods(StaticToy.folds_on_value)); by = method -> method.line)), last(sort(collect(methods(StaticToy.folds_on_value)); by = method -> method.line))])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["caller" => Tuple{typeof(StaticToy.splits_on_union), Union{Nothing, Int}}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.FollowKnown(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["caller"])
    @test Set(number for key in reached for number in records[key].positions) == Set([1, 2])
end

@testset "static map: a closure a frame creates is walked at the type of its creation, where closures that capture it hold only its wrapper" begin
    placements = method_placements([only(methods(StaticToy.lonely))])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["caller" => Tuple{typeof(StaticToy.calls_chain_at_abstract_capture), StaticToy.Held, Vector{Int}, Float32}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.FollowKnown(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["caller"])
    @test Set(number for key in reached for number in records[key].positions) == Set([1])
end

@testset "static map: a closure a handed generator holds is walked at its own type, so the closures it captured resolve" begin
    placements = method_placements([only(methods(StaticToy.lonely))])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["caller" => Tuple{typeof(StaticToy.calls_captured_closure), Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.FollowKnown(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["caller"])
    @test Set(number for key in reached for number in records[key].positions) == Set([1])
end

@testset "static map: a scope method of an outside function naming no scope type is reached where that function is called" begin
    owned_method = which(ToyOwner.owned, (Char,))
    placements = method_placements([only(methods(StaticToy.helper)), owned_method])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["caller" => Tuple{typeof(StaticToy.calls_owned), Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.DropUnresolved(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["caller"])
    @test Set(number for key in reached for number in records[key].positions) == Set([1, 2])
end

@testset "static map: a scope method of the constructor of an outside type is reached where its scope type goes to outside code" begin
    placements = method_placements([which(Base.IndexStyle, (Type{StaticToy.Scaler{Int}},))])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["holder" => Tuple{typeof(StaticToy.holds_scaler), Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.FollowKnown(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["holder"])
    @test Set(number for key in reached for number in records[key].positions) == Set([1])
end

@testset "static map: a call through a test-module import made after the world of the walk began is followed" begin
    @test walk_after_import(method_placements([only(methods(StaticToy.lonely))])) == Set([1])
end

@testset "static map: a constructor called with a type parameter known only at run time is followed" begin
    constructor = which(StaticToy.Tagged{Int}, (Int,))
    placements = method_placements([only(methods(StaticToy.helper)), constructor])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["builder" => Tuple{typeof(StaticToy.builds_tagged), Type, Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.FollowKnown(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["builder"])
    @test Set(number for key in reached for number in records[key].positions) == Set([1, 2])
end

@testset "static map: a scope method naming no scope type is reached from a frame of the package owning its function" begin
    placements = method_placements([which(ToyOwner.owned, (Char,))])
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["caller" => Tuple{typeof(StaticToy.passes_to_owner), Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.DropUnresolved(), scope, placements, seeds)
    reached = test_reachable_keys(records, ["caller"])
    @test Set(number for key in reached for number in records[key].positions) == Set([1])
end

"""Definitions of one file whose functions have the given headers and code texts."""
function text_definitions(headers::AbstractVector{String}, texts::AbstractVector{String})::Vector{StaticRecords.Definition}
    return [
        StaticRecords.Definition("a.jl", header, 3 * number, 3 * number + 2, true, StaticRecords.ast_hash(text))
            for (number, (header, text)) in enumerate(zip(headers, texts))
    ]
end

@testset "static map: the code hash of a function ignores comments, whitespace and line numbers" begin
    plain = "function f(x)\n    return x + 1\nend"
    @test StaticRecords.ast_hash(plain) == StaticRecords.ast_hash("# a comment\n\n\nfunction f(x)\n    # inside\n    return   x + 1 # trailing\nend")
    @test StaticRecords.ast_hash(plain) != StaticRecords.ast_hash("@inline function f(x)\n    return x + 1\nend")
    @test StaticRecords.ast_hash(plain) != StaticRecords.ast_hash("function f(x)\n    return x + 2\nend")
    # Across a file's definitions: a comment edit keeps every hash, a body edit changes only its own.
    headers = ["f(x)", "g(x)"]
    before = text_definitions(headers, ["f(x) = x + 1", "function g(x)\n    return x\nend"])
    commented = text_definitions(headers, ["# why\nf(x) = x + 1 # note", "function g(x)\n\n    return x\nend"])
    edited = text_definitions(headers, ["f(x) = x + 1", "function g(x)\n    return x + 1\nend"])
    @test [definition.hash for definition in commented] == [definition.hash for definition in before]
    @test [definition.hash == other.hash for (definition, other) in zip(edited, before)] == [true, false]
end

@testset "static map: a definition keeps its identity when others are added, and a repeated header is numbered" begin
    before = text_definitions(["f(x)", "g(x)", "g(x)"], ["f(x) = 1", "g(x) = 2", "g(x) = 3"])
    after = text_definitions(["new(x)", "f(x)", "g(x)", "g(x)"], ["new(x) = 0", "f(x) = 1", "g(x) = 2", "g(x) = 3"])
    identities = StaticRecords.definition_identities(before)
    @test allunique(identities)
    @test StaticRecords.definition_identities(after)[2:end] == identities
end

@testset "static map: an inlined callee is reached" begin
    names, placements = toy_placements()
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["caller" => Tuple{typeof(StaticToy.outer_of_inline), Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.DropUnresolved(), scope, placements, seeds)
    @test Set(records["caller"].positions) == Set(findall(in((:outer_of_inline, :inlined)), names))
end

@testset "static map: a method defined without a source file maps to no function and does not stop the walk" begin
    names, placements = toy_placements()
    scope = StaticRecords.Scope([StaticToy], String[])
    seeds = Pair{String, Type}["caller" => Tuple{typeof(StaticToy.calls_no_file), Int}]
    records = test_walk(Dict{String, StaticRecords.FrameRecord}(), StaticRecords.DropUnresolved(), scope, placements, seeds)
    generated = only(methods(StaticToy.no_file_function))
    @test StaticRecords.tracked_path(placements, generated) == ""
    @test StaticRecords.place(placements, generated) == 0
    @test Set(records["caller"].positions) == Set(findall(==(:calls_no_file), names))
end

@testset "static map: a signature key names partial named tuples, varargs and unions without printing them" begin
    partial = NamedTuple{ntuple(index -> Symbol("field", index), 14)}
    signatures = Type[
        Tuple{typeof(sin), partial},
        Tuple{typeof(sin), Vararg{Int}},
        Tuple{typeof(sin), Vararg},
        Tuple{typeof(sin), Union{Int, Nothing}},
        Tuple{typeof(sin), Float32},
    ]
    keys = [StaticRecords.type_key(signature) for signature in signatures]
    @test allunique(keys)
    @test keys == [StaticRecords.type_key(signature) for signature in signatures]
end

@testset "static map options reject invalid input and damaged cache files" begin
    root = mktempdir()
    options = StaticRecords.parse_options(["--root", root, "--commit", "fixture", "--unresolved", "follow-known"])
    @test StaticRecords.mode_name(options.mode) == "follow-known"
    @test_throws ErrorException StaticRecords.walk_mode("unknown")
    @test_throws ErrorException StaticRecords.parse_options(["--root", root, "--commit", "fixture", "--unresolved", "unknown"])
    @test_throws ErrorException StaticRecords.option_values(["--cache"], "--cache")
    cache = joinpath(root, "damaged.jls")
    write(cache, "damaged")
    @test StaticRecords.read_cache(cache, "fixture") isa Salsa.DefaultStorage
end

@testset "static map compilation handles imports and reports invalid bodies" begin
    test_module = Module(:BodyUnit)
    imported = StaticRecords.TestsetSource("imported", "imported", "", "@testset \"imported\" begin\nusing Test\n@test 1 == 1\nend")
    outcome = StaticRecords.compile_body(test_module, imported, 1, String[])
    @test isempty(outcome.failure)
    invalid = StaticRecords.TestsetSource("invalid", "invalid", "", "@testset \"invalid\" begin\nconst item = 1\nend")
    @test !isempty(StaticRecords.compile_body(test_module, invalid, 2, String[]).failure)
end

@testset "static map setup requires its named module" begin
    root = mktempdir()
    write(joinpath(root, "setup.jl"), "nothing\n")
    options = StaticRecords.parse_options(["--root", root, "--commit", "fixture", "--setup-file", "setup.jl", "--test-module", "AbsentStaticSetup"])
    @test_throws ErrorException StaticRecords.load_test_module(options)
    fallback = StaticRecords.parse_options(["--root", pkgdir(Fallout), "--commit", "fixture"])
    @test StaticRecords.source_module(fallback, Module(:EmptyStaticModule)) === Fallout
end

@testset "static IR fallbacks retain unknown types and calls" begin
    code = first(Base.code_typed_by_type(Tuple{typeof(sin), Float64})).first
    code.slottypes = nothing
    code.ssavaluetypes = nothing
    @test StaticRecords.value_type(code, Core.SSAValue(1)) === Any
    @test StaticRecords.value_type(code, Core.Argument(1)) === Any
    @test StaticRecords.value_type(code, Core.SlotNumber(1)) === Any
    @test StaticRecords.value_type(code, GlobalRef(Main, :absent_static_name)) === Any
    @test StaticRecords.widened(1) === Any
    @test StaticRecords.splatted_types(Tuple{Int, String}) == Type[Int, String]
    @test isempty(StaticRecords.splatted_types(Tuple{Int, Vararg{String}}))
    @test isempty(StaticRecords.splatted_types(code, Core.SSAValue(1)))
    @test isempty(StaticRecords.splatted_types(code, Core.Argument(1)))
    @test StaticRecords.InferenceWalk.invoked_instance(1) === nothing
    @test !StaticRecords.InferenceWalk.mentions_module(Int, StaticToy, 7)
    @test StaticRecords.InferenceWalk.mentions_module(Union{Int, StaticToy.Probe}, StaticToy, 0)
    names = Set{Core.TypeName}()
    StaticRecords.scope_type_names!(names, Module[StaticToy], Union{T, Int} where {T <: StaticToy.Probe}, 0)
    @test StaticToy.Probe.name in names
    scope = StaticRecords.Scope([StaticToy], String[])
    @test !StaticRecords.known_callee(scope, Any)
    @test !StaticRecords.known_callee(scope, Union{})
    @test StaticRecords.method_matches(nothing) === nothing
    @test isempty(StaticRecords.method_matches(Core.MethodMatch[]))
    @test StaticRecords.matched_site_edges(nothing, scope, false, StaticRecords.DropUnresolved()).unknown
    @test StaticRecords.function_type_head(TypeVar(:T, Union{}, Function)) === Function
    @test isempty(StaticRecords.typed_frames(Union{}))
    untyped = StaticRecords.frame_edges(StaticRecords.FollowUnresolved(), Tuple{typeof(StaticToy.lonely), Missing}, scope)
    @test untyped.everything
    @test "an untyped frame" in untyped.unresolved
    optimized = first(StaticRecords.typed_frames(Tuple{typeof(StaticToy.outer), Int})).first
    invoked = Core.CodeInstance[first(statement.args) for statement in optimized.code if statement isa Expr && statement.head === :invoke && first(statement.args) isa Core.CodeInstance]
    @test !isempty(invoked)
    @test only(methods(StaticToy.inner)) in StaticRecords.definition_methods(first(invoked))
    constructor_type = Base.unwrap_unionall(Type{T} where {T <: Union{}})
    if constructor_type isa DataType
        @test StaticRecords.function_owner(constructor_type) === Core
    else
        @test constructor_type isa Core.TypeEq
    end
    if VERSION >= v"1.14.0-alpha2"
        partition = Base.lookup_binding_partition(Base.get_world_counter(), GlobalRef(Base, :sin))
        constant_partition = Core.eval(Main, Expr(:new, Core.BindingPartition, QuoteNode(Core.Const(3)), partition.min_world, partition.max_world, QuoteNode(partition.next), partition.kind))
        @test StaticRecords.value_type(code, constant_partition) === Int
    end
end

@testset "static helper options cover both platform separators and optional macro prefixes" begin
    @test StaticRecords.load_path_separator(true) == ';'
    @test StaticRecords.load_path_separator(false) == ':'
    @test StaticRecords.macro_prefix("custom_testset") == ""
    @test StaticRecords.mentioned_identifiers("@custom_testset \"case\"") == ["case"]
    @test StaticRecords.other_mentions("@custom_testset \"case\"") == ["case"]
    buffer = IOBuffer()
    StaticRecords.write_type(buffer, Vararg{Int, 2})
    @test occursin("vararg{Core.Int64,Int64:2", String(take!(buffer)))
    method = only(methods(StaticToy.lonely))
    scope = StaticRecords.Scope([StaticToy], String[])
    @test method in StaticRecords.entry_edges(StaticRecords.DropUnresolved(), method, scope).methods
    @test isempty(StaticRecords.entry_edges(StaticRecords.DropUnresolved(), nothing, scope).methods)
end

@testset "static progress callback accepts completed work" begin
    timer = Timer(60)
    try
        printer = StaticRecords.ProgressPrinter(Threads.Atomic{Int}(1), 2, time_ns())
        @test isnothing(printer(timer))
    finally
        close(timer)
    end
end
