# Infer the commands and a unit while Fallout precompiles, so their methods have concrete
# specializations that load from the package image.
precompile(main, (Vector{String},))
precompile(parse_ranges, (String,))
precompile(merge_maps, (String, Vector{String}, Base.DevNull))
precompile(select_command, (String, String, Vector{String}, Bool, Base.DevNull))
precompile(
    Core.kwcall,
    (
        typeof(
            (;
                tests = "",
                suites = "",
                suite_pattern = "",
                sources = String[],
                runner = "",
                project = "",
                jobs = 1,
                timeout = 1,
                only = String[],
                shard = 1,
                shards = 1,
                commit = "",
                environment = Pair{String, String}[],
                log = devnull,
            )
        ),
        typeof(build_map),
        String,
        String,
    ),
)
precompile(Core.kwcall, (NamedTuple{(:root, :track), Tuple{String, Symbol}}, typeof(unit_cache)))
precompile(unit, (typeof(retest_pattern), UnitCache, Vector{String}))
