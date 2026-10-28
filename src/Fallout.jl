module Fallout

using Salsa
using Serialization

export MethodSignature, TestCase, FalloutSession
export update_file!, remove_file!, register_test!, record_dynamic_deps!
export symbol_hash, test_dependency_fingerprint, is_test_stale, stale_tests
export run_impacted_tests!, save_session_cache, load_session_cache!

# ============================================================================
# 1. Core Value Types (Immutable with Structural Equality for Early Cutoff)
# ============================================================================

"""
    MethodSignature(mod::Symbol, sym::Symbol)

Coarse, stable identifier representing a function/macro/type symbol in a module.
Being an immutable struct of Symbols, Julia provides structural `==` and `hash`
automatically, satisfying Salsa's early-cutoff requirement.
"""
struct MethodSignature
    mod::Symbol
    sym::Symbol
end

"""
    NormalizedAST(expr::Expr, digest::UInt64)

Wraps a trivia-stripped Julia `Expr` alongside its precomputed structural hash.
Salsa's `_memoized_lookup_internal` checks `new_value == old_value` to decide
whether to backdate a revision; comparing `digest` makes this O(1) and immune
to `LineNumberNode` shifts.
"""
struct NormalizedAST
    expr::Expr
    digest::UInt64
end

Base.:(==)(a::NormalizedAST, b::NormalizedAST) = a.digest == b.digest && a.expr == b.expr
Base.hash(a::NormalizedAST, h::UInt) = hash(a.digest, h)

"""
    TestCase(id::Symbol, path::String, runner::Function)

Metadata for a registered test item. Kept outside `@derived` execution.
"""
struct TestCase
    id::Symbol
    path::String
    mod::Symbol
end

# ============================================================================
# 2. AST Normalization & Static Extraction Helpers
# ============================================================================

"""
    strip_trivia(x)

Recursively strips `LineNumberNode`s and docstrings from parsed Julia `Expr`s
so whitespace, comment, and line-offset changes do not invalidate AST queries.
"""
function strip_trivia(ex::Expr)
    if ex.head === :macrocall &&
            length(ex.args) >= 3 &&
            ex.args[1] === GlobalRef(Core, Symbol("@doc"))
        # Strip docstring text, keep only the documented expression
        return strip_trivia(ex.args[end])
    end
    cleaned_args = Any[]
    for arg in ex.args
        arg isa LineNumberNode && continue
        push!(cleaned_args, strip_trivia(arg))
    end
    return Expr(ex.head, cleaned_args...)
end
strip_trivia(x) = x

function parse_and_strip_trivia(text::String)::NormalizedAST
    raw_expr = Meta.parseall(text)
    cleaned = strip_trivia(raw_expr)
    return NormalizedAST(cleaned, hash(cleaned))
end

"""
    extract_function_name(sig_expr) -> Union{Symbol, Nothing}

Extracts the base function or struct `Symbol` from a method/type definition head.
"""
function extract_function_name(ex)
    ex isa Symbol && return ex
    if ex isa Expr
        if ex.head === :call ||
                ex.head === :where ||
                ex.head === :(::) ||
                ex.head === :curly
            return extract_function_name(ex.args[1])
        elseif ex.head === :. && length(ex.args) == 2 && ex.args[2] isa QuoteNode
            return ex.args[2].value
        end
    end
    return nothing
end

"""
    extract_definitions!(defs::Dict{Symbol, UInt64}, ex)

Walks a normalized AST and maps each defined symbol to a rolling hash of all its
method/type bodies in that file.
"""
function extract_definitions!(defs::Dict{Symbol, UInt64}, ex)
    ex isa Expr || return defs
    if ex.head === :function ||
            (ex.head === :(=) && !isempty(ex.args) && ex.args[1] isa Expr)
        fname = extract_function_name(ex.args[1])
        if fname !== nothing
            defs[fname] = hash(ex, get(defs, fname, UInt64(0)))
        end
    elseif ex.head === :struct || ex.head === :abstract || ex.head === :primitive
        tname = extract_function_name(ex.args[ex.head === :struct ? 2 : 1])
        if tname !== nothing
            defs[tname] = hash(ex, get(defs, tname, UInt64(0)))
        end
    elseif ex.head === :const && !isempty(ex.args)
        cname = extract_function_name(ex.args[1] isa Expr ? ex.args[1].args[1] : ex.args[1])
        if cname !== nothing
            defs[cname] = hash(ex, get(defs, cname, UInt64(0)))
        end
    else
        for arg in ex.args
            extract_definitions!(defs, arg)
        end
    end
    return defs
end

"""
    extract_called_symbols!(called::Set{Symbol}, ex)

Extracts static function call targets from a normalized test AST.
"""
function extract_called_symbols!(called::Set{Symbol}, ex)
    ex isa Expr || return called
    if ex.head === :call && !isempty(ex.args)
        callee = extract_function_name(ex.args[1])
        callee !== nothing && push!(called, callee)
    end
    for arg in ex.args
        extract_called_symbols!(called, arg)
    end
    return called
end

# ============================================================================
# 3. Salsa Inputs (Layer 1: Disk Text, Module Topology, and Dynamic Deps)
# ============================================================================

# Raw source text on disk keyed by stable file path
@declare_input file_text(rt, path::String)::String

# Files belonging to a given Julia module (e.g., :MyPkg => ["src/MyPkg.jl", "src/utils.jl"])
@declare_input module_files(rt, mod::Symbol)::Vector{String}

# Source file and target module associated with a specific test ID
@declare_input test_source_path(rt, test_id::Symbol)::String
@declare_input test_target_module(rt, test_id::Symbol)::Symbol

# Dynamic method dependencies captured from Core.MethodInstance backedges / coverage
@declare_input recorded_dynamic_deps(rt, test_id::Symbol)::Vector{MethodSignature}

# ============================================================================
# 4. Salsa Derived Queries (Layers 2–5: Coarse-to-Fine Early Cutoff)
# ============================================================================

"""
    normalized_ast(rt, path::String)::NormalizedAST

Layer 2 (Coarse Derived): Parses `file_text` and strips whitespace, comments,
and `LineNumberNode`s. Absorbs non-semantic edits via early cutoff.
"""
@derived function normalized_ast(rt, path::String)::NormalizedAST
    text = file_text(rt, path)
    return parse_and_strip_trivia(text)
end

"""
    file_definitions(rt, path::String)::Dict{Symbol, UInt64}

Layer 3 (Medium Derived): Extracts a file-level symbol table mapping defined
symbols to their expression hashes. Absorbs edits localized to a single function.
"""
@derived function file_definitions(rt, path::String)::Dict{Symbol, UInt64}
    ast = normalized_ast(rt, path)
    defs = Dict{Symbol, UInt64}()
    extract_definitions!(defs, ast.expr)
    return defs
end

"""
    symbol_hash(rt, mod::Symbol, sym::Symbol)::UInt64

Layer 4 (Fine Derived): Computes the combined hash for a single symbol `sym`
across all files included in `mod`. Backdates whenever edits in `mod`'s files
do not alter `sym` itself.
"""
@derived function symbol_hash(rt, mod::Symbol, sym::Symbol)::UInt64
    paths = module_files(rt, mod)
    acc = hash((mod, sym))
    found = false
    for path in paths
        defs = file_definitions(rt, path)
        if haskey(defs, sym)
            acc = hash(defs[sym], acc)
            found = true
        end
    end
    # Return a stable sentinel hash for external/Base symbols not defined in `mod`
    return found ? acc : hash((:external, mod, sym))
end

"""
    static_called_symbols(rt, test_id::Symbol)::Vector{MethodSignature}

Extracts static call-graph dependencies from the test file's normalized AST.
"""
@derived function static_called_symbols(rt, test_id::Symbol)::Vector{MethodSignature}
    path = test_source_path(rt, test_id)
    target_mod = test_target_module(rt, test_id)
    ast = normalized_ast(rt, path)
    syms = Set{Symbol}()
    extract_called_symbols!(syms, ast.expr)
    sorted_syms = sort!(collect(syms))
    return [MethodSignature(target_mod, s) for s in sorted_syms]
end

"""
    test_dependency_fingerprint(rt, test_id::Symbol)::UInt64

Layer 5 (Leaf Derived): Computes the combined fingerprint of the test's own
normalized AST plus the `symbol_hash` of every static and dynamically recorded
dependency.
"""
@derived function test_dependency_fingerprint(rt, test_id::Symbol)::UInt64
    t_path = test_source_path(rt, test_id)
    t_ast = normalized_ast(rt, t_path)

    static_deps = static_called_symbols(rt, test_id)
    dynamic_deps = recorded_dynamic_deps(rt, test_id)

    all_deps = sort!(unique(vcat(static_deps, dynamic_deps)); by = d -> (d.mod, d.sym))

    dep_hashes = UInt64[symbol_hash(rt, d.mod, d.sym) for d in all_deps]
    return hash((t_ast.digest, dep_hashes))
end

# ============================================================================
# 5. Session State & Runner Orchestration (Outside Salsa @derived)
# ============================================================================

"""
    FalloutSession

Holds the `Salsa.Runtime` alongside the external `last_passed_fingerprint` table
and registered test cases. Keeping `last_passed_fingerprint` outside Salsa
ensures failed tests are always re-run and test execution never locks Salsa.
"""
mutable struct FalloutSession
    rt::Salsa.Runtime
    tests::Dict{Symbol, TestCase}
    last_passed_fingerprint::Dict{Symbol, UInt64}
end

function FalloutSession()
    return FalloutSession(Salsa.Runtime(), Dict{Symbol, TestCase}(), Dict{Symbol, UInt64}())
end

"""
    update_file!(session::FalloutSession, path::String, text::String = read(path, String); mod::Union{Symbol, Nothing}=nothing)

Updates a source or test file's text in the Salsa runtime and optionally registers
the path under `mod`.
"""
function update_file!(
    session::FalloutSession,
    path::String,
    text::String = read(path, String);
    mod::Union{Symbol, Nothing} = nothing,
)
    set_file_text!(session.rt, path, text)
    if mod !== nothing
        existing = try
            copy(module_files(session.rt, mod))
        catch
            String[]
        end
        if !(path in existing)
            push!(existing, path)
            sort!(existing)
            set_module_files!(session.rt, mod, existing)
        end
    end
    return nothing
end

"""
    remove_file!(session::FalloutSession, path::String; mod::Union{Symbol, Nothing}=nothing)

Removes a deleted file from the Salsa input tables.
"""
function remove_file!(
    session::FalloutSession,
    path::String;
    mod::Union{Symbol, Nothing} = nothing,
)
    delete_file_text!(session.rt, path)
    if mod !== nothing
        existing = try
            filter(!=(path), module_files(session.rt, mod))
        catch
            String[]
        end
        set_module_files!(session.rt, mod, existing)
    end
    return nothing
end

"""
    register_test!(session::FalloutSession, test_id::Symbol, path::String, target_mod::Symbol; text::Union{String, Nothing}=nothing)

Registers a test item and initializes its inputs in the Salsa runtime.
"""
function register_test!(
    session::FalloutSession,
    test_id::Symbol,
    path::String,
    target_mod::Symbol;
    text::Union{String, Nothing} = nothing,
)
    file_contents = text === nothing ? read(path, String) : text
    set_file_text!(session.rt, path, file_contents)
    set_test_source_path!(session.rt, test_id, path)
    set_test_target_module!(session.rt, test_id, target_mod)
    set_recorded_dynamic_deps!(session.rt, test_id, MethodSignature[])
    session.tests[test_id] = TestCase(test_id, path, target_mod)
    return session.tests[test_id]
end

"""
    record_dynamic_deps!(session::FalloutSession, test_id::Symbol, deps::Vector{MethodSignature})

Updates the dynamic method dependencies observed during a test run (e.g., from
`Core.MethodInstance` backedges).
"""
function record_dynamic_deps!(
    session::FalloutSession,
    test_id::Symbol,
    deps::Vector{MethodSignature},
)
    set_recorded_dynamic_deps!(session.rt, test_id, deps)
    return nothing
end

"""
    is_test_stale(session::FalloutSession, test_id::Symbol)::Bool

Queries Salsa for the test's current dependency fingerprint and compares it
against `last_passed_fingerprint`.
"""
function is_test_stale(session::FalloutSession, test_id::Symbol)::Bool
    current_fp = test_dependency_fingerprint(session.rt, test_id)
    last_fp = get(session.last_passed_fingerprint, test_id, UInt64(0))
    return current_fp != last_fp
end

"""
    stale_tests(session::FalloutSession)::Vector{Symbol}

Returns a sorted list of all registered `test_id`s whose dependency fingerprint
has changed since their last passing run (or that have never passed).
"""
function stale_tests(session::FalloutSession)::Vector{Symbol}
    impacted = Symbol[id for id in keys(session.tests) if is_test_stale(session, id)]
    return sort!(impacted)
end

"""
    run_impacted_tests!(executor::Function, session::FalloutSession)::Dict{Symbol, Bool}

Identifies all stale tests via Salsa, executes each via `executor(test_case)`
outside of Salsa's runtime, and updates `last_passed_fingerprint` only for tests
that pass.

`executor(tc::TestCase)` may return either a `Bool` (`passed`) or a tuple
`(passed::Bool, dynamic_deps::Vector{MethodSignature})`.
"""
function run_impacted_tests!(executor::Function, session::FalloutSession)::Dict{
    Symbol,
    Bool,
}
    results = Dict{Symbol, Bool}()
    for test_id in stale_tests(session)
        tc = session.tests[test_id]
        exec_out = executor(tc)
        if exec_out isa Tuple{Bool, Vector{MethodSignature}}
            passed, dyn_deps = exec_out
            record_dynamic_deps!(session, test_id, dyn_deps)
        else
            passed = Bool(exec_out)
        end

        results[test_id] = passed
        if passed
            # Re-query in case dynamic_deps were updated during this run
            session.last_passed_fingerprint[test_id] = test_dependency_fingerprint(
                session.rt,
                test_id,
            )
        end
    end
    return results
end

# ============================================================================
# 6. Disk Persistence for CLI Usage
# ============================================================================

"""
    save_session_cache(path::String, session::FalloutSession)

Serializes `last_passed_fingerprint` to disk so CLI runs can skip unchanged tests.
"""
function save_session_cache(path::String, session::FalloutSession)
    open(path, "w") do io
        serialize(io, session.last_passed_fingerprint)
    end
end

"""
    load_session_cache!(path::String, session::FalloutSession)

Loads previously passing test fingerprints from disk if the cache file exists.
"""
function load_session_cache!(path::String, session::FalloutSession)
    isfile(path) || return session
    open(path, "r") do io
        cached = deserialize(io)
        if cached isa Dict{Symbol, UInt64}
            merge!(session.last_passed_fingerprint, cached)
        end
    end
    return session
end

end # module Fallout
