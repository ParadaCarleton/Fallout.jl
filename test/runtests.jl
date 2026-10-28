using Test
using Fallout

@testset "Fallout.jl + Salsa.jl Incremental TIA" begin
    session = FalloutSession()

    # 1. Seed source files in module :DemoPkg
    utils_src_v1 = """
    "Computes foo."
    foo(x) = x + 1
    bar(y) = y * 2
    """
    update_file!(session, "src/utils.jl", utils_src_v1; mod = :DemoPkg)

    # 2. Register two tests: one calling `foo`, one calling `bar`
    register_test!(
        session,
        :test_foo,
        "test/test_foo.jl",
        :DemoPkg;
        text = "@assert foo(1) == 2",
    )
    register_test!(
        session,
        :test_bar,
        "test/test_bar.jl",
        :DemoPkg;
        text = "@assert bar(3) == 6",
    )

    # Initially both tests are stale (never passed)
    @test stale_tests(session) == [:test_bar, :test_foo]

    # Run all stale tests and mark them passed
    run_count = Dict(:test_foo => 0, :test_bar => 0)
    run_impacted_tests!(session) do tc
        run_count[tc.id] += 1
        return true
    end
    @test run_count[:test_foo] == 1
    @test run_count[:test_bar] == 1
    @test isempty(stale_tests(session))

    # 3. Coarse Early Cutoff: Comment, docstring, and whitespace changes
    utils_src_v2 = """
    # Added a comment and extra blank lines
    "Updated docstring with typo fix."
    foo(x) = x + 1


    bar(y) = y * 2
    """
    update_file!(session, "src/utils.jl", utils_src_v2; mod = :DemoPkg)
    @test isempty(stale_tests(session))

    # 4. Fine Early Cutoff: Modify `bar(y)` -> only `:test_bar` is invalidated
    utils_src_v3 = """
    foo(x) = x + 1
    bar(y) = y * 3
    """
    update_file!(session, "src/utils.jl", utils_src_v3; mod = :DemoPkg)
    @test stale_tests(session) == [:test_bar]
    @test !is_test_stale(session, :test_foo)

    # 5. Failed-Test Retry: Failed tests do not update `last_passed_fingerprint`
    run_impacted_tests!(session) do tc
        run_count[tc.id] += 1
        return false # Simulate test failure
    end
    @test stale_tests(session) == [:test_bar]

    # Re-run and pass
    run_impacted_tests!(session) do tc
        run_count[tc.id] += 1
        return true
    end
    @test isempty(stale_tests(session))

    # 6. Dynamic Dependencies: Record a dynamic edge from `:test_foo` to `bar`
    record_dynamic_deps!(session, :test_foo, [MethodSignature(:DemoPkg, :bar)])
    @test stale_tests(session) == [:test_foo]
end
