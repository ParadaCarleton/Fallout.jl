# Writing tests with units

A unit is a piece of a test whose result Fallout stores and reuses. A unit runs again
only when the code it executed, its configuration, or the environment changes. Use units
when a test spends minutes or hours computing something that its checks then inspect:
model fits, simulation replicates, solver sweeps, large fixtures.

```julia
using Test
using Fallout: unit, unit_cache
using MyPackage: simulate_replicate, rank_statistics

const CACHE = unit_cache()

@testset "calibration" begin
    replicates = [unit(simulate_replicate, CACHE, (; seed, draws = 1000)) for seed in 1:200]
    @test rank_statistics(replicates).uniform_p > 1e-3
end
```

The first run computes all 200 replicates. Later runs read them back, unless the code
the replicates ran has changed. Edit `rank_statistics` or the `@test` line and only the
checks run again. Edit a function that `simulate_replicate` calls and the replicates are
computed again. Edit a comment, a docstring, a blank line or an unrelated function and
nothing is computed again.

## Setup

Units run inside the test process, unlike `fallout select`. Add Fallout to the test
dependencies (`test/Project.toml`, or `[extras]` and `[targets]`),
and add the cache directory to `.gitignore`:

```
.fallout/
```

Run the tests with coverage of the whole repository:

```
julia --project=. -e 'using Pkg; Pkg.test(coverage = true)'
julia --project=test --code-coverage=@. --code-coverage=.fallout/coverage.info test/runtests.jl
```

`Pkg.test(coverage = true)` tracks the package root and leaves `.cov` files beside the
sources. The second form tracks `.` and writes one tracefile instead.

## Rules

1. **Split the computation from the checks.** A unit returns data; the `@test`s run
   outside it, on what it returns. A failing check never discards a computed result.

2. **Pass every input through `config`.** `unit(compute, cache, config)` calls
   `compute(config)`. `compute` must capture nothing: a closure, or a callable struct
   with fields, is an error. Put seeds, sizes, tolerances and options in `config`. Fallout
   hashes `config` with StableHashTraits, so use plain values: numbers, strings, symbols,
   tuples, named tuples, arrays, dictionaries and structs of these.

3. **Seed from `config`.** Draw random numbers from `Random.Xoshiro(config.seed)`, never
   from the global generator. A stored result must be the result the same config would
   compute again.

4. **Make units small enough to lose.** One unit per replicate, shard or parameter point.
   A crash, a `Ctrl-C` or a code edit then costs at most the units in progress. Units
   finished before the interruption are reused on the next run.

5. **Make `compute` a named top-level function.** A unit is identified by its function's
   module-qualified name and its `config`. An anonymous function or `do` block is an
   error, because its generated name shifts when unrelated code above it changes. A
   `compute` defined outside the tracked directory is also an error. Fallout tracks code
   by top-level item (a function, a struct, a `const`, a whole `@testset`), so keep
   `compute` and its helpers out of `@testset` blocks, in the package or in a test helper
   file.

6. **Return plain data.** Results are stored with `Serialization`. Return numbers, arrays,
   named tuples and your own structs. Do not return functions, tasks, open files, pointers
   or locks. Prefer the summaries the checks need (ranks, quantiles, errors) to the raw
   objects (whole chains, whole solutions): they store and load faster.

7. **Put data files in `config`.** Fallout tracks code, not the files that code reads.
   When a unit reads a file, add its digest to the config, for example
   `(; seed, data = bytes2hex(SHA.sha1(read(path))))`.

8. **Run units one at a time per process under coverage.** Coverage counters belong to
   the whole process, so a unit cannot tell its lines from another thread's. A unit
   started while another unit computes is an error, nested units included. Parallelize
   across processes (`Distributed.pmap`, several machines) instead. Code inside a unit may
   use threads freely. Do not run other threaded work beside a computing unit.

## Tracking modes

| `track` | A unit depends on | Needs | Use when |
| --- | --- | --- | --- |
| `:coverage` (default) | The items it executed, and the definitions they mention | `--code-coverage=@ROOT` | Iterating on code a long test runs |
| `:sources` | Every `.jl` file under `root` | Nothing | Coverage slows the computation too much, or units run on threads |

Coverage instrumentation slows only code under the tracked directory, never your
dependencies. Measured on Julia 1.13: a loop dominated by math calls ran at the same
speed; a `Dict`-heavy loop ran 35% slower; a tight loop over small inlined functions ran
many times slower, because the counters block the optimizations that removed the loop.
Measure your own units before choosing.

Under `:sources`, any edit to code under `root` recomputes every unit. Blanks, comments
and docstrings still do not count.

## What every unit depends on

- Its function's module-qualified name, and its `config`.
- Julia's version, and the active project's `Project.toml`, manifest and
  `LocalPreferences.toml` (pass `project` to `unit_cache` to name another project).
  Upgrading a dependency recomputes every unit.
- Under `:coverage`, the code tokens of every top-level item it executed under the tracked
  directory. Comments, blank lines and docstrings are not code tokens.
- Under `:coverage`, for every name those items mention: the code of the `const`s,
  globals, structs and macros of that name (followed through the names they mention), and
  the signature headers of its methods. Adding a method to a function the unit calls
  recomputes it.

## Sharing a cache between machines

`unit_cache(; dir)` names the directory the results go to. Point several machines at one
shared directory, or copy it between them with `rsync`. A machine reuses a result only
when its Julia version, project, manifest and preferences match the machine that stored
it, so check out the same manifest everywhere. Results are written to a temporary file
and then renamed, so a reader never sees half a result. Two machines that compute the
same unit at once both store it; the second write replaces the first.

## Blind spots

- **Code outside the tracked directory.** A package added with `Pkg.develop` from a path
  outside it is invisible: the manifest records its path, not its code. Track a directory
  that holds every package you edit.
- **Inputs outside `config`.** Data files, environment variables, the thread count, and
  global state that code outside the unit changes. Put each one that matters in `config`.
- **Code built from strings.** Code made by `include_string`, `eval(Meta.parse(...))` or
  files written at run time is not parsed when the cache is made. Under coverage, a unit
  that runs a file the cache did not parse logs a warning and is never reused.
- **Edits during a run.** The cache parses the tree when `unit_cache()` runs. Make it after
  the package loads and do not edit the sources until the run ends. With Revise, make a
  new cache after each revision.

## Housekeeping

- `unit_cache(; refresh = true)` recomputes every unit once and stores the new results.
- Old results stay in `dir` until you delete them. Delete `.fallout/units` to start again.
- `@info` logs each computed unit with its time. `JULIA_DEBUG=Fallout` also logs each
  reused one.

## Units and test selection

`fallout select` chooses which testsets an edit can affect; units choose which parts of
a selected testset must run again. Use both: select the testsets, and let units inside
them reuse whatever the edit did not reach.
