using Documenter, Fallout

# The home page is the README, with its links rewritten for the docs tree.
write(
    joinpath(@__DIR__, "src", "index.md"),
    replace(
        read(joinpath(@__DIR__, "..", "README.md"), String),
        "docs/src/units.md" => "units.md",
    ),
)

makedocs(;
    sitename = "Fallout.jl",
    authors = "Carlos Parada",
    modules = [Fallout],
    format = Documenter.HTML(
        canonical = "https://paradacarleton.github.io/Fallout.jl/stable",
    ),
    pages = ["Home" => "index.md", "Units" => "units.md", "API" => "api.md"],
    warnonly = false,
)

deploydocs(repo = "github.com/ParadaCarleton/Fallout.jl.git", push_preview = true)
