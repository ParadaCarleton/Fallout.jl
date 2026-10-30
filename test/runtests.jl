# Self-check of the selector on a throwaway git repository with a hand-written map:
#     julia --startup-file=no --project=. -e 'using Pkg; Pkg.test()'   (from the package's directory)
using Test
using Fallout:
    Fallout,
    executed_positions,
    lcov_files,
    merge_maps,
    parse_ranges,
    ranges_text,
    read_map,
    retest_pattern,
    runner_arguments,
    select_testsets

const PACKAGE = """
module P
"A thing."
struct S
    a::Int
end
f(x) = x + 1
function g(x::Int)
    return 2x
end
h(s::S) = s.a
unused(x) = x
end
"""

const TESTS = """
using Test
helper() = 1
@testset "runs f" begin
    @test P.f(1) == 2
end
@testset "runs g" begin
    @test P.g(1) == 2
end
@testset "uses S" begin
    @test P.h(P.S(1)) == 1
end
@testset "helper user" begin
    @test helper() == 1
end
"""

function git_run(root::AbstractString, args::AbstractString...)::String
    command = `git -C $root -c user.name=check -c user.email=check@example.com $(collect(args))`
    return read(command, String)
end

function write_file(
        root::AbstractString,
        path::AbstractString,
        text::AbstractString,
    )::Nothing
    mkpath(dirname(joinpath(root, path)))
    write(joinpath(root, path), text)
    return nothing
end

"A repository holding the package and its tests at one commit, and a map built from it."
function fixture(root::AbstractString)::String
    git_run(root, "init", "-q")
    write_file(root, "Project.toml", "name = \"P\"\n")
    write_file(root, "src/P.jl", PACKAGE)
    write_file(root, "test/runtests.jl", TESTS)
    git_run(root, "add", "-A")
    git_run(root, "commit", "-q", "-m", "base")
    commit = strip(git_run(root, "rev-parse", "HEAD"))
    map = """
    [meta]
    commit = "$commit"
    tests = "test/runtests.jl"
    runner = "test/retest.jl"
    sources = ["src"]
    [definitions]
    "src/P.jl" = ["f(x)", "g(x::Int)", "h(s::S)", "unused(x)"]
    [testsets."runs f"]
    status = "ok"
    ms = 1
    functions = { "src/P.jl" = "1" }
    [testsets."runs g"]
    status = "ok"
    ms = 1
    functions = { "src/P.jl" = "2" }
    [testsets."uses S"]
    status = "ok"
    ms = 1
    functions = { "src/P.jl" = "3" }
    [testsets."helper user"]
    status = "ok"
    ms = 1
    functions = {}
    """
    write_file(root, "map.toml", map)
    write_file(root, ".gitignore", "map.toml\n.gitignore\n")
    return commit
end

"The selection after replacing `old` by `new` in `path` (working tree, not committed)."
function selected_after(
        root::AbstractString,
        path::AbstractString,
        old::AbstractString,
        new::AbstractString,
    )::Fallout.Selection
    original = read(joinpath(root, path), String)
    @assert occursin(old, original)
    write_file(root, path, replace(original, old => new))
    map = read_map(joinpath(root, "map.toml"))
    try
        return select_testsets(root, map, map.commit, "")
    finally
        write_file(root, path, original)
    end
end

names_in(selection::Fallout.Selection)::Vector{String} = sort(
    unique(
        first.(selection.reasons),
    )
)

@testset "selector" begin
    root = mktempdir()
    fixture(root)

    @test names_in(selected_after(root, "src/P.jl", "x + 1", "x + 2")) == ["runs f"]
    @test isempty(
        names_in(
            selected_after(
                root,
                "src/P.jl",
                "\"A thing.\"",
                "\"Another thing.\"",
            )
        )
    )
    @test isempty(
        names_in(
            selected_after(
                root,
                "src/P.jl",
                "f(x) = x + 1",
                "f(x) = x + 1 # note",
            )
        )
    )

    struct_change = selected_after(root, "src/P.jl", "a::Int", "a::Float32")
    @test names_in(struct_change) == ["uses S"]

    dispatch = selected_after(
        root,
        "src/P.jl",
        "function g(x::Int)",
        "function g(x::Integer)",
    )
    @test names_in(dispatch) == ["runs g"]
    @test any(occursin("dispatch", last(pair)) for pair in dispatch.reasons)

    unused_change = selected_after(root, "src/P.jl", "unused(x) = x", "unused(x) = 2x")
    @test isempty(names_in(unused_change))
    @test length(unused_change.uncovered) == 1

    @test names_in(
        selected_after(
            root,
            "test/runtests.jl",
            "P.g(1) == 2",
            "P.g(2) == 4",
        )
    ) ==
        ["runs g"]
    @test names_in(
        selected_after(
            root,
            "test/runtests.jl",
            "helper() = 1",
            "helper() = 2",
        )
    ) ==
        ["helper user"]

    full = selected_after(
        root,
        "Project.toml",
        "name = \"P\"",
        "name = \"P\"\nversion = \"0.1.0\"",
    )
    @test names_in(full) == ["helper user", "runs f", "runs g", "uses S"]
    @test !isempty(full.full)

    @test_throws "cannot parse" selected_after(root, "src/P.jl", "x + 1", "x + )")

    # A line break between tokens can change the code: `return\n2x` returns nothing.
    @test names_in(selected_after(root, "src/P.jl", "return 2x", "return\n2x")) ==
        ["runs g"]
    @test isempty(
        names_in(
            selected_after(
                root,
                "src/P.jl",
                "    return 2x",
                "\n    return 2x",
            )
        )
    )
    operator = selected_after(
        root,
        "src/P.jl",
        "unused(x) = x",
        "unused(x) = x\nBase.:(==)(a::S, b::S) = true",
    )
    @test names_in(operator) == ["helper user", "runs f", "runs g", "uses S"]
end

@testset "an import changes the names it stops importing, not the ones it starts importing" begin
    root = mktempdir()
    commit = fixture(root)
    # `h` mentions `S`: an import of `S` reaches it only by dropping the name.
    @test isempty(
        names_in(
            selected_after(
                root,
                "src/P.jl",
                "module P\n",
                "module P\nusing Q: S\n",
            )
        )
    )

    write_file(root, "src/P.jl", replace(PACKAGE, "module P\n" => "module P\nusing Q: S\n"))
    git_run(root, "commit", "-q", "-am", "import S")
    imported = strip(git_run(root, "rev-parse", "HEAD"))
    write_file(
        root,
        "map.toml",
        replace(read(joinpath(root, "map.toml"), String), commit => imported),
    )
    @test names_in(selected_after(root, "src/P.jl", "using Q: S\n", "")) == ["uses S"]
    @test isempty(
        names_in(
            selected_after(
                root,
                "src/P.jl",
                "using Q: S\n",
                "using Q: S, T\n",
            )
        )
    )
end

@testset "pattern and coverage records" begin
    pattern = Regex(retest_pattern(["a (b)", "c.d"]))
    @test occursin(pattern, "/a (b)")
    @test occursin(pattern, "/a (b)/inner")
    @test occursin(pattern, "/c.d")
    @test !occursin(pattern, "/a (b) more")
    @test !occursin(pattern, "/cxd")
    @test !occursin(pattern, "/x/a (b)")

    @test ranges_text([9, 1, 2, 3, 5, 9]) == "1-3,5,9"
    @test parse_ranges("1-3,5,9") == [1:3, 5:5, 9:9]

    root = mktempdir()
    tracefile = "SF:$root/src/a.jl\nDA:1,1\nDA:2,0\nDA:3,4\nend_of_record\nSF:/elsewhere/b.jl\nDA:1,1\nend_of_record\n"
    @test lcov_files(tracefile, root, ["src"]) == Dict("src/a.jl" => [1, 3])
    @test executed_positions([6, 8, 9], [6:6, 7:9, 10:10]) == "1-2"
end

function shard_map(commit::AbstractString, testset::AbstractString)::String
    return """
    [meta]
    commit = "$commit"
    tests = "test/runtests.jl"
    runner = "test/retest.jl"
    sources = ["src"]
    [definitions]
    "src/P.jl" = ["f(x)", "g(x::Int)"]
    [testsets."$testset"]
    status = "ok"
    ms = 1
    functions = { "src/P.jl" = "1" }
    """
end

@testset "shard merge" begin
    root = mktempdir()
    write(joinpath(root, "one.toml"), shard_map("c0ffee", "runs f"))
    write(joinpath(root, "two.toml"), shard_map("c0ffee", "runs g"))
    write(joinpath(root, "again.toml"), shard_map("c0ffee", "runs g"))
    write(joinpath(root, "other.toml"), shard_map("beef", "uses S"))
    merge_maps(
        joinpath(root, "map.toml"),
        [joinpath(root, "one.toml"), joinpath(root, "two.toml")],
    )
    @test sort(collect(keys(read_map(joinpath(root, "map.toml")).testsets))) ==
        ["runs f", "runs g"]
    @test_throws "more than one shard" merge_maps(
        joinpath(root, "map.toml"),
        [joinpath(root, "two.toml"), joinpath(root, "again.toml")],
    )
    @test_throws "another commit" merge_maps(
        joinpath(root, "map.toml"),
        [joinpath(root, "one.toml"), joinpath(root, "other.toml")],
    )
    @test read_map(joinpath(root, "one.toml")).project == "."
    write(
        joinpath(root, "nested.toml"),
        replace(
            shard_map("c0ffee", "uses S"),
            "[definitions]" => "project = \"test\"\n[definitions]",
        ),
    )
    @test read_map(joinpath(root, "nested.toml")).project == "test"
    @test_throws "other files" merge_maps(
        joinpath(root, "map.toml"),
        [joinpath(root, "one.toml"), joinpath(root, "nested.toml")],
    )
end

@testset "identity survives an unrelated edit above a covered function" begin
    root = mktempdir()
    fixture(root)
    write_file(
        root,
        "src/P.jl",
        replace(PACKAGE, "f(x) = x + 1" => "extra(x) = x\nf(x) = x + 1"),
    )
    git_run(root, "commit", "-q", "-a", "-m", "unrelated edit above f")
    base = strip(git_run(root, "rev-parse", "HEAD"))
    map = read_map(joinpath(root, "map.toml"))
    write_file(
        root,
        "src/P.jl",
        replace(read(joinpath(root, "src/P.jl"), String), "x + 1" => "x + 2"),
    )
    @test names_in(select_testsets(root, map, base, "")) == ["runs f"]
end

@testset "functions the map lacks and functions that moved" begin
    root = mktempdir()
    fixture(root)
    fresh = selected_after(root, "src/P.jl", "unused(x) = x", "unused(x) = x\nfresh(x) = x")
    @test isempty(names_in(fresh))
    @test any(occursin("`fresh`", line) for line in fresh.uncovered)

    write_file(root, "src/P.jl", replace(PACKAGE, "h(s::S) = s.a\n" => "extra(x) = x\n"))
    write_file(root, "src/Q.jl", "h(s::S) = s.a\n")
    git_run(root, "add", "-A")
    git_run(root, "commit", "-q", "-m", "move h to Q.jl, add extra")
    base = strip(git_run(root, "rev-parse", "HEAD"))
    map = read_map(joinpath(root, "map.toml"))

    write_file(root, "src/Q.jl", "h(s::S) = s.a + 1\n")
    @test names_in(select_testsets(root, map, base, "")) == ["uses S"]

    write_file(root, "src/Q.jl", "h(s::S) = s.a\n")
    write_file(
        root,
        "src/P.jl",
        replace(
            read(joinpath(root, "src/P.jl"), String),
            "extra(x) = x" => "extra(x) = 2x",
        ),
    )
    lacking = select_testsets(root, map, base, "")
    @test isempty(names_in(lacking))
    @test any(occursin("`extra`", line) for line in lacking.uncovered)
end

"The text `main(args)` prints to stdout."
function printed_by_main(args::AbstractVector{<:AbstractString})::String
    path = tempname()
    open(path, "w") do io
        redirect_stdout(io) do
            Fallout.main(args)
        end
    end
    return read(path, String)
end

@testset "select diffs against the map's commit" begin
    root = mktempdir()
    first_commit = fixture(root)
    extended = replace(PACKAGE, "f(x) = x + 1" => "extra(x) = x\nf(x) = x + 1")
    write_file(root, "src/P.jl", extended)
    git_run(root, "commit", "-q", "-a", "-m", "trunk moves on after the map")
    git_run(root, "checkout", "-q", "-b", "topic")
    write_file(root, "src/P.jl", replace(extended, "x + 1" => "x + 2"))
    git_run(root, "commit", "-q", "-a", "-m", "topic edits f")
    arguments = ["select", "--root", root, "--map", joinpath(root, "map.toml"), "--to", "topic"]

    # The trunk commit after the map adds `extra`, so the map's commit sees two changes.
    text = printed_by_main(arguments)
    @test occursin("diff $(first(first_commit, 12)) ->", text)
    @test occursin("selected 1 testsets\n  runs f  <- runs changed `f`", text)
    @test occursin("map lacks 1 of 2 changed functions", text)

    explicit = printed_by_main(vcat(arguments, ["--base", "topic~1"]))
    @test occursin("map lacks 0 of 1 changed functions", explicit)
    @test_throws "no --trunk" Fallout.main(vcat(arguments, ["--trunk", "main"]))
end

@testset "a name is a static-analysis helper only when every definition of it is" begin
    root = mktempdir()
    fixture(root)
    helpers = """
    scan_sources() = readdir("src")
    struct Wrapped
        value::Int
    end
    Wrapped(value::Float64) = error("leak: ", scan_sources())
    """
    write_file(root, "test/helpers.jl", helpers)
    tests = replace(TESTS, "using Test\n" => "using Test\ninclude(\"helpers.jl\")\n") *
        """
        @testset "scans" begin
            @test !isempty(scan_sources())
        end
        @testset "wraps" begin
            @test Wrapped(1).value == 1
        end
        """
    write_file(root, "test/runtests.jl", tests)
    git_run(root, "add", "-A")
    git_run(root, "commit", "-q", "-m", "helpers")
    base = strip(git_run(root, "rev-parse", "HEAD"))
    write_file(
        root,
        "src/P.jl",
        replace(PACKAGE, "unused(x) = x" => "unused(x) = x # note\nother(x) = x"),
    )
    selection = select_testsets(root, read_map(joinpath(root, "map.toml")), base, "")
    static = sort(
        [
            first(pair)
                for pair in selection.reasons
                if startswith(last(pair), "static analysis")
        ]
    )
    @test static == ["scans"]
end

@testset "macro names are identifiers on every supported Julia" begin
    items = Fallout.source_items("@testset \"t\" begin\n    @check x\nend\n", "macros.jl")
    @test only(items).kind == :testset
    @test "check" in only(items).mentions
end

"A repository whose test files are suites of their own, and a map built from it with `--suites test`."
function suite_fixture(root::AbstractString)::String
    git_run(root, "init", "-q")
    write_file(root, "Project.toml", "name = \"P\"\n")
    write_file(root, "src/P.jl", PACKAGE)
    write_file(root, "test/runtests.jl", "for suite in ARGS\n    include(suite)\nend\n")
    write_file(root, "test/support/helper.jl", "helper() = 1\n")
    write_file(
        root,
        "test/a/test_f.jl",
        "using Test\n@testset \"f\" begin\n    @test P.f(1) == 2\nend\n",
    )
    write_file(
        root,
        "test/test_g.jl",
        "using Test\ninclude(\"support/helper.jl\")\n@testset \"g\" begin\n    @test P.g(helper()) == 2\nend\n",
    )
    write_file(root, "test/test_h.jl", "include(\"support/setup.jl\")\n")
    write_file(
        root,
        "test/support/setup.jl",
        "using Test\nsetup() = 1\n@testset \"inner\" begin\n    @test setup() == 1\nend\n",
    )
    git_run(root, "add", "-A")
    git_run(root, "commit", "-q", "-m", "base")
    commit = strip(git_run(root, "rev-parse", "HEAD"))
    map = """
    [meta]
    commit = "$commit"
    tests = "test/runtests.jl"
    runner = "test/runtests.jl"
    suites = "test"
    suite_pattern = '^test_.*\\.jl\$'
    sources = ["src"]
    [definitions]
    "src/P.jl" = ["f(x)", "g(x::Int)", "h(s::S)", "unused(x)"]
    [testsets."a/test_f.jl"]
    status = "ok"
    ms = 1
    functions = { "src/P.jl" = "1" }
    [testsets."test_g.jl"]
    status = "ok"
    ms = 1
    functions = { "src/P.jl" = "2" }
    [testsets."test_h.jl"]
    status = "ok"
    ms = 1
    functions = {}
    """
    write_file(root, "map.toml", map)
    write_file(root, ".gitignore", "map.toml\n.gitignore\n")
    return commit
end

@testset "suite files are testsets, run by path" begin
    root = mktempdir()
    suite_fixture(root)
    @test read_map(joinpath(root, "map.toml")).suites == "test"

    @test names_in(selected_after(root, "src/P.jl", "x + 1", "x + 2")) == ["a/test_f.jl"]
    @test names_in(selected_after(root, "src/P.jl", "return 2x", "return 3x")) ==
        ["test_g.jl"]

    edited = selected_after(root, "test/a/test_f.jl", "P.f(1) == 2", "P.f(2) == 3")
    @test names_in(edited) == ["a/test_f.jl"]
    @test any(occursin("edited suite", last(pair)) for pair in edited.reasons)
    @test isempty(
        names_in(
            selected_after(
                root,
                "test/a/test_f.jl",
                "using Test\n",
                "using Test # note\n",
            )
        )
    )

    @test names_in(
        selected_after(
            root,
            "test/support/helper.jl",
            "helper() = 1",
            "helper() = 2",
        )
    ) ==
        ["test_g.jl"]

    write_file(root, "test/test_new.jl", "@testset \"new\" begin\nend\n")
    write_file(root, "test/not_a_suite.jl", "x = 1\n")
    map = read_map(joinpath(root, "map.toml"))
    fresh = select_testsets(root, map, map.commit, "")
    @test names_in(fresh) == ["test_new.jl"]
    rm(joinpath(root, "test/test_new.jl"))
    rm(joinpath(root, "test/not_a_suite.jl"))

    runner = selected_after(
        root,
        "test/runtests.jl",
        "include(suite)",
        "include(joinpath(@__DIR__, suite))",
    )
    @test names_in(runner) == ["a/test_f.jl", "test_g.jl", "test_h.jl"]
    @test !isempty(runner.full)

    # A helper the suite runs only through an include, and a testset inside it, belong to the suite.
    @test names_in(
        selected_after(
            root,
            "test/support/setup.jl",
            "setup() = 1",
            "setup() = 2",
        )
    ) ==
        ["test_h.jl"]

    @test runner_arguments(true, ["a/test_f.jl", "test_g.jl"]) ==
        ["a/test_f.jl", "test_g.jl"]
    @test runner_arguments(false, ["x"]) == [retest_pattern(["x"])]
end

@testset "environment files of the package and the runner's project select the full suite" begin
    dependency_file = Fallout.dependency_file
    @test dependency_file("Project.toml", ["src"], ".")
    @test dependency_file("Manifest-v1.12.toml", ["src"], ".")
    @test dependency_file("pkg/Project.toml", ["pkg/src"], ".")
    @test dependency_file("pkg/test/Project.toml", ["pkg/src"], "pkg/test")
    @test !dependency_file("pkg/docs/Project.toml", ["pkg/src"], "pkg/test")
    @test !dependency_file("pkg/test/Project.toml", ["pkg/src"], ".")
    @test !dependency_file("pkg/src/data.toml", ["pkg/src"], ".")
end

@testset "a non-.jl file is a fixture, data of the package holding a source, or ignored" begin
    path_class = Fallout.path_class
    @test path_class("pkg/test/table.csv", Set{String}(), "pkg/test", ["pkg/src"]) == :fixture
    @test path_class("pkg/data/table.csv", Set{String}(), "pkg/test", ["pkg/src"]) == :data
    @test path_class("README.md", Set{String}(), "test", ["src"]) == :data
    @test path_class("docs/index.md", Set{String}(), "pkg/test", ["pkg/src"]) == :ignored
end

@testset "path options take the form git reports paths in" begin
    path_option = Fallout.path_option
    @test path_option("./test/") == "test"
    @test path_option("./test/runtests.jl") == "test/runtests.jl"
    @test path_option(".") == "."
    @test path_option("pkg/../test") == "test"
end

"Each top-level item of `text` as `kind name key,key`."
function described(text::AbstractString)::Vector{String}
    return [
        string(item.kind, " ", item.name, " ", join(item.keys, ','))
            for item in Fallout.source_items(text, "q.jl")
    ]
end

@testset "the parser names every kind of top-level item" begin
    @test described("x ⊕ y = x + y") == ["function ⊕ ⊕"]
    @test described("(s::S)(y) = y") == ["function S S"]
    @test described("(::S{T})(y) where {T} = y") == ["function S S"]
    @test described("f(x)::Int = 1") == ["function f f"]
    @test described("const a, (b, c) = 1, (2, 3)") == ["binding  a,b,c"]
    @test described("data = [1]") == ["binding  data"]
    @test described("A.field = 1") == ["binding  "]
    @test described("macro twice(x)\n    :(2 * \$x)\nend") == ["binding twice twice"]
    @test described("@inline @noinline f(x) = x") == ["function f f"]
    @test described("@marker") == ["other  "]
    @test described("42") == ["other  "]
    @test described("@time @testset \"timed\" begin end") == ["testset timed timed"]
    @test described("@testset NAME begin end") == ["testset  "]
    @test isempty(described("# only a comment\n"))
    for spelled in ("getfield(M, :TOL)", "M.TOL", "var\"TOL\"", "getglobal(M, Symbol(\"TOL\"))")
        @test "TOL" in only(Fallout.source_items("f() = $spelled", "q.jl")).mentions
    end
    for built in ("Symbol(prefix, \"TOL\")", "Symbol(\"TO\" * \"L\")", "\"TOL\"")
        @test !("TOL" in only(Fallout.source_items("f() = $built", "q.jl")).mentions)
    end
    @test only(Fallout.source_items("module P\nmodule A\ng() = 1\nend\nend", "q.jl")).scope == "P.A"
    @test_throws "cannot parse q.jl" described("f(x = \n")

    items = Fallout.source_items(
        "struct S end\nconst V = Vector{S}\nconst W = V\nk(v::W) = 1\ninclude(\"a.jl\")",
        "q.jl",
    )
    located = [Fallout.Located("q.jl", item) for item in items if item.kind != :function]
    @test Fallout.name_closure(Set(["S"]), located) == Set(["S", "V", "W"])
    @test Fallout.binding_keys(last(items)) == String[]
    @test Fallout.binding_keys(only(item for item in items if item.kind == :function)) == ["k"]
    @test ranges_text(Int[]) == ""
    @test Fallout.path_class("test/data.csv", Set{String}(), "test", ["src"]) == :fixture
    @test Fallout.parse_file_change("a/n.jl b/n.jl\nnew file mode 100644\n").status == :added
    @test Fallout.parse_file_change("a/d.jl b/d.jl\ndeleted file mode 100644\n").status == :deleted
    old = joinpath(mktempdir(), "old.toml")
    write(old, "[meta]\ncommit = \"abc\"\n")
    @test_throws "rebuild it with `build`" read_map(old)
end

"""
A runner that runs the top-level testsets of the fixture's test files whose `/name`
matches the regex `ARGS[1]`, as ReTest does.
"""
const RUNNER = """
using Test
using P
const PATTERN = Regex(only(ARGS))
const FILES = ("runtests.jl", "slow.jl")
for expression in (part for file in FILES for part in Meta.parseall(read(joinpath(@__DIR__, file), String)).args)
    if Meta.isexpr(expression, :macrocall) && first(expression.args) == Symbol("@testset")
        _, _, name = expression.args
        if !occursin(PATTERN, "/" * name)
            continue
        end
    end
    Core.eval(Main, expression)
end
"""

"The text `command` prints to standard output when run through `Fallout.main`."
function printed(command::AbstractVector{<:AbstractString})::String
    path, io = mktemp()
    # fatou-ignore discouraged-function: this is the `redirect_stdout(f, io)` form, with a named `f`
    redirect_stdout(Fallout.main ∘ Returns(command), io)
    close(io)
    return read(path, String)
end

@testset "build, merge, select and run a real repository" begin
    root = mktempdir()
    fixture(root)
    project = "name = \"P\"\nuuid = \"f0000000-0000-4000-8000-000000000001\"\n"
    write_file(root, "Project.toml", project)
    write_file(root, "test/retest.jl", RUNNER)
    tests = read(joinpath(root, "test/runtests.jl"), String)
    looped = "for round in 1:1\n    @testset \"looped\" begin end\nend\n"
    write_file(root, "test/runtests.jl", tests * looped)
    stubborn = "@testset \"stubborn\" begin\n    Base.exit_on_sigint(false)\n    try\n        sleep(600)\n    catch\n        sleep(600)\n    end\nend\n"
    write_file(root, "test/slow.jl", "@testset \"slow\" begin\n    sleep(600)\nend\n" * stubborn)
    write_file(root, "test/computed.jl", "using Test\n@testset \"\$(1 + 1)\" begin end\n")
    git_run(root, "add", "-A")
    git_run(root, "commit", "-q", "-m", "runner")
    common = ["--root", root, "--runner", "test/retest.jl", "--env", "FALLOUT_CHECK=1"]
    Fallout.main(["build", common..., "--map", "built.toml", "--jobs", "4", "--timeout", "60", "--only", "runs", "--only", "uses", "--only", "helper"])
    built = read_map(joinpath(root, "built.toml"))
    @test built.commit == strip(git_run(root, "rev-parse", "HEAD"))
    @test built.testsets["helper user"].status == "no-coverage"
    @test all(built.testsets[name].status == "ok" for name in ("runs f", "runs g", "uses S"))
    @test built.testsets["runs f"].functions == Dict("src/P.jl" => Set(["f(x)"]))
    @test built.testsets["uses S"].functions == Dict("src/P.jl" => Set(["h(s::S)"]))

    for shard in ("1/2", "2/2")
        Fallout.main(["build", common..., "--map", "shard-$(first(shard)).toml", "--shard", shard, "--jobs", "1", "--only", "r", "--only", "u", "--commit", built.commit])
    end
    Fallout.main(["merge", "--root", root, "--map", "merged.toml", "--in", "shard-1.toml", "--in", "shard-2.toml"])
    merged = read_map(joinpath(root, "merged.toml"))
    @test Dict(name => (testset.status, testset.functions) for (name, testset) in merged.testsets) ==
        Dict(name => (testset.status, testset.functions) for (name, testset) in built.testsets)
    @test_throws "more than one shard" Fallout.main(["merge", "--root", root, "--map", "twice.toml", "--in", "shard-1.toml", "--in", "shard-1.toml"])

    Fallout.main(["build", common..., "--map", "slow.toml", "--tests", "test/slow.jl", "--timeout", "1"])
    slow = read_map(joinpath(root, "slow.toml"))
    @test all(slow.testsets[name].status == "timeout" for name in ("slow", "stubborn"))
    @test_throws "no testset matches" Fallout.main(["build", common..., "--only", "absent"])
    @test_throws "computed name" Fallout.main(["build", common..., "--tests", "test/computed.jl"])

    write_file(root, "src/P.jl", replace(PACKAGE, "return 2x" => "return x + x"))
    @test_throws "differs from commit" Fallout.main(["build", common..., "--map", "dirty.toml"])
    selection = ["--root", root, "--map", "built.toml"]
    @test occursin("pattern: ", printed(["select", selection...]))
    @test occursin("runs g", printed(["run", selection...]))
    write_file(root, "Project.toml", project * "version = \"0.1.0\"\n")
    @test occursin("FULL SUITE: Project.toml", printed(["select", selection...]))
    @test_throws "is not a git checkout" Fallout.main(["select", "--root", joinpath(root, "src"), "--map", "../built.toml", "--base", "HEAD"])
    @test_throws "usage" Fallout.main(String[])
    @test_throws "needs a value" Fallout.main(["build", "--map"])
end

"""
Run the unit scenarios' `phase` in a child process. It tracks coverage of this package,
which holds `tree`, so the child's runs of Fallout count toward the package's coverage.
"""
function unit_phase(tree::AbstractString, phase::AbstractString)::Bool
    script = joinpath(@__DIR__, "units_scenarios.jl")
    command = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) --code-coverage=@$(pkgdir(Fallout)) $script $tree $phase`
    return success(pipeline(command; stdout, stderr))
end

@testset "units reuse results while the code they ran is unchanged" begin
    tree = mktempdir(pkgdir(Fallout))
    mkpath(joinpath(tree, "src"))
    @test unit_phase(tree, "coverage")
    @test unit_phase(tree, "reuse")
    uncovered = `$(Base.julia_cmd()) --startup-file=no --code-coverage=none --project=$(Base.active_project()) -e 'using Fallout; unit_cache()'`
    message = IOBuffer()
    @test !success(pipeline(uncovered; stderr = message))
    @test occursin("--code-coverage=@DIR", String(take!(message)))
    @test_throws "--code-coverage=@DIR" Fallout.tracked_root(0, "")
    @test_throws "--code-coverage=@DIR" Fallout.tracked_root(1, "")
    @test Fallout.tracked_root(1, tree) == tree
end

@testset "a changed data file selects the testsets that read it; a failed row reruns" begin
    root = mktempdir()
    commit = fixture(root)
    package = replace(
        PACKAGE,
        "f(x) = x + 1" => "f(x) = x + 1 + 0 * length(read(joinpath(@__DIR__, \"table.csv\")))",
        "return 2x" => "return 2x + 0 * length(TABLE)",
        "unused(x) = x" => "const TABLE = \"other.csv\"\nunused(x) = x\nisfile(\"notes.txt\")",
    )
    write_file(root, "src/P.jl", package)
    write_file(root, "src/table.csv", "1\n")
    write_file(root, "src/other.csv", "2\n")
    write_file(root, "README.md", "P\n")
    write_file(root, "src/notes.txt", "n\n")
    git_run(root, "add", "-A")
    git_run(root, "commit", "-q", "-m", "data files")
    head = strip(git_run(root, "rev-parse", "HEAD"))
    write_file(root, "map.toml", replace(read(joinpath(root, "map.toml"), String), commit => head))

    direct = selected_after(root, "src/table.csv", "1", "3")
    @test names_in(direct) == ["runs f"]
    @test any(occursin("reads changed file `table.csv`", last(pair)) for pair in direct.reasons)
    @test names_in(selected_after(root, "src/other.csv", "2", "3")) == ["runs g"]
    unread = selected_after(root, "README.md", "P", "Q")
    @test isempty(names_in(unread))
    @test any(occursin("README.md", line) for line in unread.notes)
    toplevel = selected_after(root, "src/notes.txt", "n", "m")
    @test isempty(names_in(toplevel))
    @test any(occursin("notes.txt", line) for line in toplevel.notes)

    write_file(root, "map.toml", replace(read(joinpath(root, "map.toml"), String), "[testsets.\"uses S\"]\nstatus = \"ok\"" => "[testsets.\"uses S\"]\nstatus = \"failed\""))
    weak = selected_after(root, "README.md", "P", "Q")
    @test names_in(weak) == ["uses S"]
    @test any(startswith(last(pair), "map status failed") for pair in weak.reasons)
end

@testset "the environment fingerprint follows resolved packages, not path-tracked ones" begin
    root = mktempdir()
    fingerprint = Fallout.environment_fingerprint
    bare = fingerprint(root, ".")
    manifest(sha) = """
    [[deps.A]]
    uuid = "00000000-0000-0000-0000-00000000000a"
    git-tree-sha1 = "$sha"
    [[deps.P]]
    path = "."
    uuid = "00000000-0000-0000-0000-00000000000b"
    """
    write_file(root, "Manifest.toml", manifest("1111"))
    first_resolution = fingerprint(root, ".")
    @test first_resolution != bare
    write_file(root, "Manifest.toml", replace(manifest("1111"), "path = \".\"" => "path = \"elsewhere\""))
    @test fingerprint(root, ".") == first_resolution
    write_file(root, "Manifest.toml", manifest("2222"))
    @test fingerprint(root, ".") != first_resolution
end

"""
A repository with a real runner, so `build`, `update` and `audit` record real coverage. The
runner loads the package with `using`, so its definitions do not run under coverage.
"""
function recorded_fixture(root::AbstractString)::Nothing
    git_run(root, "init", "-q")
    write_file(root, "Project.toml", "name = \"P\"\nuuid = \"f0000000-0000-4000-8000-000000000001\"\n")
    write_file(root, "src/P.jl", PACKAGE)
    write_file(root, "test/runtests.jl", "using P\nfor suite in ARGS\n    include(joinpath(@__DIR__, suite))\nend\n")
    write_file(root, "test/test_f.jl", "using Test\n@testset \"f\" begin\n    @test P.f(1) == 2\nend\n")
    write_file(root, "test/test_g.jl", "using Test\n@testset \"g\" begin\n    @test P.g(1) == 2\nend\n")
    write_file(root, ".gitignore", "*.toml.work/\n*map*.toml\n")
    git_run(root, "add", "-A")
    git_run(root, "commit", "-q", "-m", "base")
    return nothing
end

"Rewrite the map at `path` after `edit` changes its parsed document in place."
function edit_map(edit::Function, path::AbstractString)::Nothing
    document = Fallout.TOML.parsefile(path)
    edit(document)
    open(io -> Fallout.TOML.print(io, document; sorted = true), path, "w")
    return nothing
end

@testset "update re-records only what changed and equals a fresh build; audit catches a wrong row" begin
    root = mktempdir()
    recorded_fixture(root)
    map_path = joinpath(root, "map.toml")
    common = ["--root", root, "--jobs", "1", "--timeout", "600"]
    Fallout.main(vcat(["build", "--map", map_path, "--suites", "test", "--runner", "test/runtests.jl"], common))
    built = read_map(map_path)
    base = built.commit
    @test built.testsets["test_f.jl"].functions["src/P.jl"] == Set(["f(x)"])
    @test built.testsets["test_g.jl"].functions["src/P.jl"] == Set(["g(x::Int)"])

    # A kept row naming a function no file defines is a selection gap; a changed environment
    # leaves the kept rows unverified.
    edit_map(map_path) do document
        document["meta"]["environment"] = "stale"
        push!(document["definitions"]["src/P.jl"], "ghost(x)")
        document["testsets"]["test_f.jl"]["functions"]["src/P.jl"] = "1,5"
    end
    write_file(root, "src/P.jl", replace(PACKAGE, "return 2x" => "return x + x", "f(x) = x + 1" => "extra(x) = x\nf(x) = x + 1"))
    git_run(root, "commit", "-q", "-am", "edit g, add extra above f")
    head = strip(git_run(root, "rev-parse", "HEAD"))
    printed_by_main(vcat(["update", "--map", map_path, "--env", "FALLOUT_CHECK=1"], common))
    updated = read_map(map_path)
    @test updated.commit == head
    @test updated.env == ["FALLOUT_CHECK=1"]
    @test updated.testsets["test_g.jl"].commit == head
    @test updated.testsets["test_f.jl"].commit == base
    @test updated.testsets["test_f.jl"].verified == ""
    @test updated.testsets["test_f.jl"].functions["src/P.jl"] == Set(["f(x)"])
    @test updated.definitions["src/P.jl"] == ["extra(x)", "f(x)", "g(x::Int)", "h(s::S)", "unused(x)"]

    fresh_path = joinpath(root, "fresh-map.toml")
    Fallout.main(vcat(["build", "--map", fresh_path, "--suites", "test", "--runner", "test/runtests.jl"], common))
    fresh = read_map(fresh_path)
    @test fresh.definitions == updated.definitions
    @test Dict(name => row.functions for (name, row) in fresh.testsets) == Dict(name => row.functions for (name, row) in updated.testsets)

    edit_map(map_path) do document
        document["testsets"]["test_f.jl"]["functions"] = Dict{String, Any}("src/P.jl" => "3")
    end
    @test_throws "differ from the map" printed_by_main(vcat(["audit", "--map", map_path, "--budget", "60"], common))
    audited = read_map(map_path)
    @test audited.testsets["test_f.jl"].functions["src/P.jl"] == Set(["f(x)"])
    @test audited.testsets["test_f.jl"].verified > updated.testsets["test_f.jl"].verified
    printed_by_main(vcat(["audit", "--map", map_path, "--budget", "60"], common))

    edit_map(map_path) do document
        document["meta"]["environment"] = "stale"
        push!(document["definitions"]["src/P.jl"], "ghost(x)")
    end
    @test occursin("note: the map was recorded", printed_by_main(["select", "--map", map_path, "--root", root]))
    @test_throws "rebuild it with `build`" printed_by_main(vcat(["audit", "--map", map_path], common))
    git_run(root, "commit", "-q", "--allow-empty", "-m", "empty")
    @test_throws "run `update` first" printed_by_main(vcat(["audit", "--map", map_path], common))

    write_file(root, "test/test_new.jl", "using Test\n")
    @test_throws "differs from HEAD" printed_by_main(vcat(["update", "--map", map_path], common))
    rm(joinpath(root, "test/test_new.jl"))
    write_file(root, "src/P.jl", PACKAGE)
    @test_throws "differs from HEAD" printed_by_main(vcat(["update", "--map", map_path], common))
end
