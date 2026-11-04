"""Create a committed package with two testsets for static map integration."""
function static_fixture(root::AbstractString)::String
    git_run(root, "init", "-q")
    write_file(root, "Project.toml", "name = \"P\"\nuuid = \"f0000000-0000-4000-8000-000000000001\"\n")
    write_file(root, "src/P.jl", "module P\nexport f, g\n\"\"\"First annotation.\"\"\"\n@noinline f(x::Int) = x + 1\n@noinline g(x::Int) = x * 2\nend\n")
    write_file(root, "test/runtests.jl", "using Test\ninclude(\"../src/P.jl\")\nusing .P\n@testset \"calls f\" begin\n    @test P.f(1) == 2\nend\n@testset \"calls g\" begin\n    @test P.g(2) == 4\nend\n")
    write_file(root, ".gitignore", "map.toml\ncache/\n")
    git_run(root, "add", "-A")
    git_run(root, "commit", "-q", "-m", "fixture")
    return strip(git_run(root, "rev-parse", "HEAD"))
end

@testset "partial maps select uncompiled testsets after source edits" begin
    root = mktempdir()
    fixture(root)
    map_text = read(joinpath(root, "map.toml"), String)
    write_file(root, "map.toml", replace(map_text, "[testsets.\"helper user\"]\nstatus = \"ok\"" => "[testsets.\"helper user\"]\nstatus = \"no-coverage\""))
    write_file(root, "src/P.jl", replace(PACKAGE, "unused(x) = x" => "unused(x) = x + 1"))
    map = read_map(joinpath(root, "map.toml"))
    @test map.testsets["helper user"].status == "no-coverage"
    selection = select_testsets(root, map, map.commit, "")
    @test "helper user" in first.(selection.reasons)
end

"""Run a static build in a child and return its diagnostic output."""
function static_build_log(root::AbstractString; workers::Integer = 1, options::Vector{String} = String[])::String
    log = tempname()
    script = joinpath(pkgdir(Fallout), "bin", "fallout.jl")
    arguments = [
        "build", "--static", "--root", String(root), "--map", "map.toml",
        "--cache", "cache", "--workers", string(workers), "--unresolved", "drop",
        "--progress-interval", "1",
        options...,
    ]
    command = `$(Base.julia_cmd()) --startup-file=no --project=$(pkgdir(Fallout)) $script $arguments`
    try
        run(pipeline(command; stdout = log, stderr = log))
    catch
        println(stderr, read(log, String))
        rethrow()
    end
    return read(log, String)
end

@testset "static setup and custom testset macro" begin
    root = mktempdir()
    static_fixture(root)
    write_file(root, "test/runtests.jl", "@custom_testset \"calls f\" begin\n    @test P.f(1) == 2\nend\n")
    write_file(root, "test/static_helper.jl", "const STATIC_HELPER = 1\n")
    write_file(root, "test/static_setup.jl", "module CustomTests\nusing Test\ninclude(\"static_helper.jl\")\ninclude(\"../src/P.jl\")\nusing .P\n@testset \"must not run\" error(\"setup executed a testset\")\nend\n")
    git_run(root, "add", "-A")
    git_run(root, "commit", "-q", "-m", "custom suite")
    build_options = String[
        "--setup-file", "test/static_setup.jl", "--test-module", "CustomTests",
        "--extra-testset-macro", "custom_testset=custom: ", "--unresolved", "approximate",
    ]
    log = static_build_log(root; options = build_options)
    map = read_map(joinpath(root, "map.toml"))
    @test map.testsets["custom: calls f"].functions == Dict("src/P.jl" => Set(["f(x::Int)"]))
    @test occursin("recalculated 1 testsets", log)
    warm = static_build_log(root; options = build_options)
    @test occursin("inferred 0 frames; recalculated 0 testsets", warm)
    write_file(root, "test/static_helper.jl", "const STATIC_HELPER = 2\n")
    git_run(root, "commit", "-q", "-a", "-m", "setup helper")
    changed = static_build_log(root; options = build_options)
    @test occursin("recalculated 1 testsets", changed)
end

"""Select from a stale static map and return the rebuild diagnostics."""
function static_select_log(root::AbstractString)::String
    log = tempname()
    script = joinpath(pkgdir(Fallout), "bin", "fallout.jl")
    command = `$(Base.julia_cmd()) --startup-file=no --project=$(pkgdir(Fallout)) $script select --root $root --map map.toml`
    try
        run(pipeline(command; stdout = log, stderr = log))
    catch
        println(stderr, read(log, String))
        rethrow()
    end
    return read(log, String)
end

@testset "select preserves a coverage map" begin
    root = mktempdir()
    fixture(root)
    original = read(joinpath(root, "map.toml"), String)
    static_select_log(root)
    @test read(joinpath(root, "map.toml"), String) == original
end

@testset "select builds an absent static map and records uncertain testsets" begin
    root = mktempdir()
    static_fixture(root)
    write_file(root, "test/runtests.jl", "using Test\ninclude(\"../src/P.jl\")\nusing .P\n@testset \"invalid body\" begin\n    const item = 1\nend\n@testset \"dynamic call\" begin\n    @test Base.invokelatest(identity, 1) == 1\nend\n")
    git_run(root, "commit", "-q", "-a", "-m", "uncertain tests")
    log = static_select_log(root)
    map = read_map(joinpath(root, "map.toml"))
    @test map.testsets["invalid body"].status == "no-coverage"
    @test occursin("recalculated 1 testsets", log)
    @test map.testsets["dynamic call"].functions == Dict("src/P.jl" => Set(["f(x::Int)", "g(x::Int)"]))
end

@testset "static preparation rejects absent and computed testset names" begin
    root = mktempdir()
    commit = static_fixture(root)
    options = Fallout.StaticMap.parse_options(["--root", root, "--commit", commit])
    write_file(root, "test/runtests.jl", "using Test\n")
    @test_throws ErrorException Fallout.StaticMap.prepare(options)
    write_file(root, "test/runtests.jl", "using Test\n@testset \"\$(1 + 1)\" begin end\n")
    @test_throws ErrorException Fallout.StaticMap.prepare(options)
end

@testset "static workers report setup failures" begin
    root = mktempdir()
    static_fixture(root)
    write_file(root, "test/failing_setup.jl", "error(\"setup failed\")\n")
    git_run(root, "add", "-A")
    git_run(root, "commit", "-q", "-m", "failing setup")
    @test_throws ProcessFailedException static_build_log(root; workers = 2, options = ["--cache", "none", "--setup-file", "test/failing_setup.jl"])
    @test !isfile(joinpath(root, "map.toml"))
end

@testset "static map builds a readable map and reuses Salsa across processes" begin
    root = mktempdir()
    first_commit = static_fixture(root)
    first_log = static_build_log(root)
    map = read_map(joinpath(root, "map.toml"))
    @test map.commit == first_commit
    @test map.testsets["calls f"].functions == Dict("src/P.jl" => Set(["f(x::Int)"]))
    @test map.testsets["calls g"].functions == Dict("src/P.jl" => Set(["g(x::Int)"]))
    @test occursin("recalculated 2 testsets", first_log)

    warm_log = static_build_log(root)
    @test occursin("inferred 0 frames; recalculated 0 testsets", warm_log)
    current_log = static_select_log(root)
    @test !occursin("[static_map] wrote", current_log)

    fingerprint = Fallout.StaticMap.builder_fingerprint()
    map_text = read(joinpath(root, "map.toml"), String)
    @test occursin(fingerprint, map_text)
    write_file(root, "map.toml", replace(map_text, fingerprint => "stale"))
    refresh_log = static_select_log(root)
    @test occursin("inferred 0 frames; recalculated 0 testsets", refresh_log)
    @test occursin(fingerprint, read(joinpath(root, "map.toml"), String))

    worker_log = static_build_log(root; workers = 2)
    @test occursin("[static_map] progress", worker_log)
    @test occursin("recalculated 2 testsets", worker_log)

    source = read(joinpath(root, "src/P.jl"), String)
    write_file(root, "src/P.jl", replace(source, "First annotation." => "Updated annotation."))
    @test_throws ProcessFailedException static_build_log(root)
    map_text = read(joinpath(root, "map.toml"), String)
    git_run(root, "commit", "-q", "-a", "-m", "annotation")
    static_select_log(root)
    @test read(joinpath(root, "map.toml"), String) == map_text
    annotation_log = static_build_log(root)
    @test occursin(r"inferred [1-9][0-9]* frames; recalculated 0 testsets", annotation_log)
    @test read_map(joinpath(root, "map.toml")).commit == strip(git_run(root, "rev-parse", "HEAD"))

    no_cache_log = static_build_log(root; options = ["--cache", "none"])
    @test occursin("recalculated 2 testsets", no_cache_log)
    updated = read(joinpath(root, "src/P.jl"), String)
    write_file(root, "src/P.jl", replace(updated, "Updated annotation." => "Final annotation."))
    git_run(root, "commit", "-q", "-a", "-m", "final annotation")
    map_text = read(joinpath(root, "map.toml"), String)
    write_file(root, "map.toml", replace(map_text, fingerprint => "stale"))
    static_select_log(root)
    @test Fallout.StaticMap.TOML.parsefile(joinpath(root, "map.toml"))["meta"]["cache"] == ""
end

"""Create a committed package whose testset's call of `k` depends on the return type of `h`, two files away."""
function chain_fixture(root::AbstractString)::Nothing
    git_run(root, "init", "-q")
    write_file(root, "Project.toml", "name = \"P\"\nuuid = \"f0000000-0000-4000-8000-000000000001\"\n")
    write_file(root, "src/P.jl", "module P\ninclude(\"h.jl\")\ninclude(\"g.jl\")\ninclude(\"k.jl\")\n@noinline function f(x::Int)\n    return k(g(x))\nend\nend\n")
    write_file(root, "src/h.jl", "function h(x::Int)\n    return x + 1\nend\n")
    write_file(root, "src/g.jl", "@noinline function g(x::Int)\n    return h(x)\nend\n")
    write_file(root, "src/k.jl", "@noinline function k(x::Int)\n    return 1\nend\n@noinline function k(x::Float64)\n    return 2\nend\n")
    write_file(root, "test/runtests.jl", "using Test\ninclude(\"../src/P.jl\")\nusing .P\n@testset \"calls f\" begin\n    @test P.f(1) > 0\nend\n")
    write_file(root, ".gitignore", "map.toml\ncache/\n")
    git_run(root, "add", "-A")
    git_run(root, "commit", "-q", "-m", "fixture")
    return nothing
end

@testset "a warm static build re-infers a frame whose callee's return type changes in another file" begin
    root = mktempdir()
    chain_fixture(root)
    static_build_log(root)
    @test read_map(joinpath(root, "map.toml")).testsets["calls f"].functions["src/k.jl"] == Set(["k(x::Int)"])
    write_file(root, "src/h.jl", "function h(x::Int)\n    return x + 1.0\nend\n")
    git_run(root, "commit", "-q", "-a", "-m", "float")
    static_build_log(root)
    warm = read_map(joinpath(root, "map.toml")).testsets["calls f"].functions["src/k.jl"]
    static_build_log(root; options = ["--cache", "none"])
    @test warm == read_map(joinpath(root, "map.toml")).testsets["calls f"].functions["src/k.jl"] == Set(["k(x::Float64)"])
end

@testset "select keeps a static map at its commit and rebuilds an outdated one there, past a dirty tree" begin
    root = mktempdir()
    chain_fixture(root)
    static_build_log(root)
    map_commit = read_map(joinpath(root, "map.toml")).commit
    write_file(root, "src/k.jl", "@noinline function k(x::Int)\n    return 3\nend\n@noinline function k(x::Float64)\n    return 2\nend\n")
    git_run(root, "commit", "-q", "-a", "-m", "edit k")
    selected = static_select_log(root)
    @test occursin("calls f", selected)
    @test read_map(joinpath(root, "map.toml")).commit == map_commit

    write_file(root, "src/h.jl", "function h(x::Int)\n    return x + 2\nend\n")
    fingerprint = Fallout.StaticMap.builder_fingerprint()
    write_file(root, "map.toml", replace(read(joinpath(root, "map.toml"), String), fingerprint => "stale"))
    refreshed = static_select_log(root)
    @test occursin("calls f", refreshed)
    map = read_map(joinpath(root, "map.toml"))
    @test map.commit == map_commit
    @test occursin(fingerprint, read(joinpath(root, "map.toml"), String))
    @test length(split(strip(git_run(root, "worktree", "list")), '\n')) == 1
end

@testset "select builds an absent static map at HEAD past a dirty tree" begin
    root = mktempdir()
    chain_fixture(root)
    write_file(root, "src/h.jl", "function h(x::Int)\n    return x + 2\nend\n")
    selected = static_select_log(root)
    @test occursin("calls f", selected)
    @test read_map(joinpath(root, "map.toml")).commit == strip(git_run(root, "rev-parse", "HEAD"))
end

@testset "a static build reads a relative root from the caller's directory and writes the default map" begin
    parent = mktempdir()
    root = joinpath(parent, "package")
    mkpath(root)
    chain_fixture(root)
    script = joinpath(pkgdir(Fallout), "bin", "fallout.jl")
    command = `$(Base.julia_cmd()) --startup-file=no --project=$(pkgdir(Fallout)) $script build --static --root package --cache none --workers 1`
    run(pipeline(Cmd(command; dir = parent); stdout = devnull, stderr = devnull))
    @test isfile(joinpath(root, Fallout.DEFAULT_MAP))
end

@testset "a static map follows testsets in test helpers and distrusts a repeated name with an uncompiled body" begin
    root = mktempdir()
    chain_fixture(root)
    write_file(
        root, "test/runtests.jl",
        """
        using Test
        include("../src/P.jl")
        using .P
        function check(x)
            @testset "inner" begin
                @test P.g(x) > 0
            end
        end
        checked = (x -> @testset "anonymous" begin @test P.h(x) > 0 end)
        @testset "via helper" begin
            check(1)
            checked(1)
        end
        @testset "repeated" begin
            @test P.h(1) > 0
        end
        @testset "repeated" begin
            const C = 1
            @test P.f(C) > 0
        end
        """,
    )
    git_run(root, "commit", "-q", "-a", "-m", "helpers")
    static_build_log(root; workers = 2)
    map = read_map(joinpath(root, "map.toml"))
    @test map.testsets["via helper"].status == "ok"
    @test map.testsets["via helper"].functions == Dict("src/g.jl" => Set(["g(x::Int)"]), "src/h.jl" => Set(["h(x::Int)"]))
    @test map.testsets["repeated"].status == "no-coverage"
end

@testset "a static setup file's include keeps its own mapexpr" begin
    root = mktempdir()
    chain_fixture(root)
    write_file(root, "test/body.jl", "@testset \"never\" error(\"ran\")\nconst MARK = :original\n")
    write_file(root, "test/static_setup.jl", "module MapTests\nusing Test\ninclude(\"../src/P.jl\")\ninclude(e -> e isa Expr && e.head === :const ? :(const MARK = :mapped) : e, \"body.jl\")\nend\n")
    test_module = Fallout.StaticMap.load_test_module(Fallout.StaticMap.parse_options(["--root", root, "--setup-file", "test/static_setup.jl", "--test-module", "MapTests"]))
    @test test_module.MARK === :mapped
end
