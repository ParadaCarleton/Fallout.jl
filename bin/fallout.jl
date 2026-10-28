#!/usr/bin/env julia

using Fallout

function discover_julia_files(dir::String)::Vector{String}
    isdir(dir) || return String[]
    files = String[]
    for (root, _, filenames) in walkdir(dir)
        for f in filenames
            endswith(f, ".jl") && push!(files, joinpath(root, f))
        end
    end
    return sort!(files)
end

function main(args::Vector{String})
    project_dir = isempty(args) ? pwd() : abspath(args[1])
    mod_name = Symbol(splitext(basename(project_dir))[1])
    cache_file = joinpath(project_dir, ".fallout_cache.jls")

    session = FalloutSession()
    load_session_cache!(cache_file, session)

    # 1. Load source files into Salsa inputs
    src_files = discover_julia_files(joinpath(project_dir, "src"))
    for path in src_files
        update_file!(session, path; mod = mod_name)
    end

    # 2. Discover test files
    test_files = discover_julia_files(joinpath(project_dir, "test"))
    for path in test_files
        test_id = Symbol(relpath(path, project_dir))
        register_test!(session, test_id, path, mod_name)
    end

    impacted = stale_tests(session)
    if isempty(impacted)
        println("Fallout: No impacted tests detected. All tests up to date.")
        return 0
    end

    println(
        "Fallout: Running $(length(impacted)) impacted test file(s): ",
        join(impacted, ", "),
    )

    results = run_impacted_tests!(session) do tc
        println("  -> Executing $(tc.path)...")
        cmd = `$(Base.julia_cmd()) --project=$project_dir $(tc.path)`
        return success(cmd)
    end

    save_session_cache(cache_file, session)

    all_passed = all(values(results))
    return all_passed ? 0 : 1
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
