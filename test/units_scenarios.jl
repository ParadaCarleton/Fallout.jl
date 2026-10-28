# Unit cache scenarios on a throwaway tree, run by runtests.jl in a process started with
# `--code-coverage=@TREE`; ARGS = [TREE, PHASE]. A unit's result carries `time_ns()`, so a
# reused result equals the stored one and a computed result is stamped during the call.
using Test
using Serialization: serialize, deserialize
using Fallout: Fallout, unit, unit_cache

const TREE = ARGS[1]
const PHASE = ARGS[2]
const SOURCE = joinpath(TREE, "src", "P.jl")
const EXPECTED = joinpath(TREE, "expected.jls")

"The throwaway package's source, with each definition replaceable."
function package_source(;
    helper::AbstractString = "helper(x) = x + K",
    constant::AbstractString = "const K = 3",
    other::AbstractString = "other(x) = x",
    extra::AbstractString = "",
    doc::AbstractString = "Fit one replicate.",
)::String
    return """
    module P
    $constant
    $helper
    "$doc"
    fit(config) = (helper(config.seed), time_ns())
    twin(config) = (0, time_ns())
    $other
    $extra
    end
    """
end

"Write `source`, load it as `Main.P`, and parse the tree into a fresh cache."
function load(source::AbstractString; keywords...)::Fallout.UnitCache
    write(SOURCE, source)
    Base.include(Main, SOURCE)
    return unit_cache(; root = TREE, keywords...)
end

"The binding `name` of `mod` in the newest world, since each `load` redefines `Main.P`."
latest(mod::Module, name::Symbol)::Any = Base.invokelatest(getglobal, mod, name)

function fit_unit(cache::Fallout.UnitCache, seed::Integer)::Tuple{Int, UInt64}
    return Base.invokelatest(unit, latest(latest(Main, :P), :fit), cache, (; seed))
end

"Whether the unit computed its result during this call, rather than reading a stored one."
function computed(cache::Fallout.UnitCache, seed::Integer)::Bool
    start = time_ns()
    return last(fit_unit(cache, seed)) > start
end

"A callable holding state, which a unit refuses."
struct Captures
    data::Int
end
(captures::Captures)(config::NamedTuple)::Int = captures.data + config.seed

"A module in the tree whose unit starts another unit while it computes."
const NESTED = """
module Nest
using Fallout: unit, unit_cache
inner(config) = config.seed
outer(config) = unit(inner, unit_cache(; root = config.root), (; seed = config.seed))
end
"""

if PHASE == "coverage"
    @testset "units under coverage" begin
        first_result = fit_unit(load(package_source()), 1)
        @test first(first_result) == 4
        @test fit_unit(load(package_source()), 1) == first_result
        commented = package_source(helper = "# adds K\nhelper(x) = x  +  K   # spaced")
        @test fit_unit(load(commented), 1) == first_result
        @test fit_unit(load(package_source(other = "other(x) = 2x")), 1) == first_result
        @test fit_unit(load(package_source(extra = "unrelated(y) = y")), 1) == first_result
        @test fit_unit(
            load(package_source(doc = "Fit a replicate, documented anew.")),
            1,
        ) ==
            first_result

        changed_helper = fit_unit(load(package_source(helper = "helper(x) = x + 2K")), 1)
        @test first(changed_helper) == 7
        @test changed_helper != first_result
        # Every stored result stays: restoring the original helper reuses the original result.
        @test fit_unit(load(package_source()), 1) == first_result

        @test computed(load(package_source(constant = "const K = 4")), 1)
        @test computed(load(package_source(extra = "helper(x::Float64) = x")), 1)
        @test computed(load(package_source()), 2)
        @test computed(load(package_source(); refresh = true), 1)
        refreshed = fit_unit(load(package_source()), 1)
        @test refreshed != first_result
        # Another function under the same config is another unit.
        twin = Base.invokelatest(
            unit,
            latest(latest(Main, :P), :twin),
            load(package_source()),
            (; seed = 1),
        )
        @test first(twin) == 0
        serialize(EXPECTED, refreshed)
    end

    @testset "units refuse unsafe computations" begin
        cache = load(package_source())
        @test_throws "capture nothing" unit(Captures(1), cache, (; seed = 1))
        @test_throws "outside the tracked root" unit(identity, cache, (; seed = 1))
        @test_throws "named top-level function" unit(
            config -> config.seed,
            cache,
            (; seed = 1),
        )
        nest = joinpath(TREE, "src", "Nest.jl")
        write(nest, NESTED)
        Base.include(Main, nest)
        outer = latest(latest(Main, :Nest), :outer)
        @test_throws "one at a time" Base.invokelatest(
            unit,
            outer,
            load(package_source()),
            (; root = TREE, seed = 1),
        )
        rm(nest)
        @test_throws "`:coverage` or `:sources`" unit_cache(; root = TREE, track = :lines)
        @test_throws "not a directory" unit_cache(; root = joinpath(TREE, "missing"))
    end

    @testset "the environment is part of a unit's key" begin
        stored = fit_unit(load(package_source()), 3)
        project = joinpath(TREE, "env", "Project.toml")
        mkpath(dirname(project))
        write(project, "[deps]\n")
        @test computed(load(package_source(); project), 3)
        @test fit_unit(load(package_source()), 3) == stored
    end

    @testset "units under source tracking" begin
        stored = fit_unit(load(package_source(); track = :sources), 5)
        @test fit_unit(
            load(package_source(helper = "helper(x) = x + K # note"); track = :sources),
            5,
        ) ==
            stored
        @test computed(load(package_source(other = "other(x) = 3x"); track = :sources), 5)
    end
elseif PHASE == "reuse"
    @testset "units persist across processes" begin
        @test fit_unit(load(package_source()), 1) == deserialize(EXPECTED)
    end
end
