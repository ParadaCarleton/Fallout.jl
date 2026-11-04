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
    git_run(root, "commit", "-q", "-a", "-m", "annotation")
    annotation_log = static_select_log(root)
    @test occursin(r"inferred [1-9][0-9]* frames; recalculated 0 testsets", annotation_log)
    @test read_map(joinpath(root, "map.toml")).commit == strip(git_run(root, "rev-parse", "HEAD"))

    no_cache_log = static_build_log(root; options = ["--cache", "none"])
    @test occursin("recalculated 2 testsets", no_cache_log)
    updated = read(joinpath(root, "src/P.jl"), String)
    write_file(root, "src/P.jl", replace(updated, "Updated annotation." => "Final annotation."))
    git_run(root, "commit", "-q", "-a", "-m", "final annotation")
    static_select_log(root)
    @test Fallout.StaticMap.TOML.parsefile(joinpath(root, "map.toml"))["meta"]["cache"] == ""
end
