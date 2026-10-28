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
        loader::AbstractString = "loader() = 1",
        from::AbstractString = "A",
        a_g::AbstractString = "1",
        b_g::AbstractString = "2",
        matrix::AbstractString = "[1 2]",
    )::String
    return """
    module P
    $constant
    $helper
    "$doc"
    fit(config) = (helper(config.seed), time_ns())
    twin(config) = (0, time_ns())
    $other
    greet(config) = config.text
    struct Solver{N}
        seed::Int
    end
    solve(config::Solver{N}) where {N} = N + config.seed
    struct Calc{N} end
    (::Calc{N})(config) where {N} = N
    $loader
    const LOADED = loader()
    fromload(config) = LOADED
    module A
    f() = 1
    g() = $a_g
    end
    module B
    f() = 2
    g() = $b_g
    end
    using .$from: f
    imported(config) = f()
    qualified(config) = A.g()
    struct S end
    same(config) = S() == S()
    shape(config) = size($matrix)
    $extra
    end
    """
end

"The unit of `P.name` on `config`, with the cache of `source`."
function named_unit(source::AbstractString, name::Symbol, config::Any; keywords...)::Any
    cache = load(source; keywords...)
    return Base.invokelatest(unit, latest(latest(Main, :P), name), cache, config)
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

    @testset "units see every change that alters their result" begin
        base = package_source()
        for text in ("hello", "")
            @test named_unit(base, :greet, (; text)) == text
            @test named_unit(base, :greet, (; text)) == text
        end
        cache = load(base)
        solver, calc = latest(latest(Main, :P), :Solver), latest(latest(Main, :P), :Calc)
        solve = latest(latest(Main, :P), :solve)
        @test Base.invokelatest(unit, solve, cache, Base.invokelatest(solver{1}, 3)) == 4
        @test Base.invokelatest(unit, solve, cache, Base.invokelatest(solver{2}, 3)) == 5
        @test Base.invokelatest(unit, Base.invokelatest(calc{1}), cache, (; seed = 1)) == 1
        @test Base.invokelatest(unit, Base.invokelatest(calc{2}), cache, (; seed = 1)) == 2

        @test named_unit(base, :fromload, (; seed = 1)) == 1
        @test named_unit(
            package_source(loader = "loader() = 2"),
            :fromload,
            (; seed = 1),
        ) ==
            2
        @test named_unit(base, :imported, (; seed = 1)) == 1
        @test named_unit(package_source(from = "B"), :imported, (; seed = 1)) == 2
        @test named_unit(base, :qualified, (; seed = 1)) == 1
        @test named_unit(package_source(a_g = "2", b_g = "1"), :qualified, (; seed = 1)) ==
            2
        @test named_unit(base, :same, (; seed = 1))
        @test !named_unit(
            package_source(extra = "Base.:(==)(a::S, b::S) = false"),
            :same,
            (; seed = 1),
        )
        @test named_unit(base, :shape, (; seed = 1)) == (1, 2)
        @test named_unit(package_source(matrix = "[1\n2]"), :shape, (; seed = 1)) == (2,)
        @test_throws "outside the directory coverage tracks" unit_cache(;
            root = mktempdir(),
        )
    end

    @testset "units follow methods defined after their cache" begin
        late = "late() = A.g()\nlatecall(config) = late()"
        for (a_g, b_g, expected) in (("1", "2", 1), ("2", "1", 2))
            write(SOURCE, package_source(; extra = late, a_g, b_g))
            cache = unit_cache(; root = TREE)
            Base.include(Main, SOURCE)
            @test Base.invokelatest(
                unit,
                latest(latest(Main, :P), :latecall),
                cache,
                (; seed = 9),
            ) ==
                expected
        end
    end

    @testset "units record code that ran before them" begin
        cache = load(package_source())
        Base.invokelatest(latest(latest(Main, :P), :fit), (; seed = 11))
        @test computed(cache, 11)
        @test computed(load(package_source(helper = "helper(x) = x + 2K")), 11)
    end

    @testset "units recompute a damaged stored result" begin
        cache = load(package_source())
        place = joinpath(
            cache.dir,
            Fallout.unit_key(
                cache,
                "Main.P.fit",
                latest(latest(Main, :P), :fit),
                (; seed = 7),
            ),
        )
        @test computed(cache, 7)
        @test all(
            endswith(file, ".jls") || endswith(file, ".toml")
                for file in readdir(place)
        )
        results = filter(endswith(".jls"), readdir(place; join = true))
        write.(results, "truncated")
        @test computed(load(package_source()), 7)
        @test !computed(load(package_source()), 7)
        records = filter(endswith(".toml"), readdir(place; join = true))
        write.(records, "result = \"forged\"\n")
        @test computed(load(package_source()), 7)
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
        @test Fallout.default_root(:coverage) == Fallout.coverage_root()
        @test Fallout.default_root(:sources) == pwd()
    end

    @testset "units never reuse code their cache did not parse" begin
        cache = load(package_source())
        late = joinpath(TREE, "src", "Late.jl")
        write(late, "module Late\nstamp(config) = time_ns()\nend\n")
        Base.include(Main, late)
        stamp = latest(latest(Main, :Late), :stamp)
        stamps = [
            @test_logs (:warn, r"did not parse") match_mode = :any Base.invokelatest(
                unit,
                stamp,
                cache,
                (; seed = 1),
            )
                for _ in 1:2
        ]
        @test allunique(stamps)
        rm(late)
    end

    @testset "the environment is part of a unit's key" begin
        stored = fit_unit(load(package_source()), 3)
        project = joinpath(TREE, "env", "Project.toml")
        mkpath(dirname(project))
        write(project, "[deps]\n")
        @test computed(load(package_source(); project), 3)
        @test fit_unit(load(package_source()), 3) == stored
        write(joinpath(dirname(project), "JuliaLocalPreferences.toml"), "[P]\nlevel = 1\n")
        @test computed(load(package_source(); project), 3)
    end

    @testset "units under source tracking" begin
        stored = fit_unit(load(package_source(); track = :sources), 5)
        @test fit_unit(
            load(package_source(helper = "helper(x) = x + K # note"); track = :sources),
            5,
        ) ==
            stored
        @test computed(load(package_source(other = "other(x) = 3x"); track = :sources), 5)
        @test computed(load(package_source(extra = "const EXTRA = 1"); track = :sources), 5)
    end
elseif PHASE == "reuse"
    @testset "units persist across processes" begin
        @test fit_unit(load(package_source()), 1) == deserialize(EXPECTED)
    end
end
