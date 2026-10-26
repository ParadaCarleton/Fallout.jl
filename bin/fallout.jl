#!/usr/bin/env julia
# Command line entry, from a clone: julia --startup-file=no bin/fallout.jl COMMAND ...
include(joinpath(@__DIR__, "..", "src", "Fallout.jl"))
Fallout.main(ARGS)
