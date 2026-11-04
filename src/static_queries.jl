using Salsa: Salsa, @declare_input, @derived

"""Runtime data used to infer signatures and locate reached methods."""
struct QueryContext{M <: WalkMode}
    mode::M
    scope::Scope
    placements::Placements
    signatures::Dict{String, Type}
    frame_runs::Threads.Atomic{Int}
    reach_runs::Threads.Atomic{Int}
end

"""A testset's reached definition numbers and unresolved sites."""
struct ReachResult
    positions::Set{Int}
    frames::Set{String}
    unresolved::Set{String}
    unmapped::Set{String}
    everything::Bool
end

Base.isequal(left::FrameRecord, right::FrameRecord)::Bool =
    isequal(Set(left.positions), Set(right.positions)) &&
    isequal(Set(left.callees), Set(right.callees)) &&
    isequal(Set(left.unresolved), Set(right.unresolved)) &&
    isequal(Set(left.unmapped), Set(right.unmapped)) &&
    isequal(left.everything, right.everything)

@declare_input source_code_hash(runtime::Salsa.Runtime, path::String)::String
@declare_input testset_code_hash(runtime::Salsa.Runtime, name::String)::String
@declare_input method_inventory_hash(runtime::Salsa.Runtime)::String

"""Infer one frame and track the source files of its methods."""
@derived function reached_frame(runtime::Salsa.Runtime, signature::Type)::FrameRecord
    context = Salsa.context(runtime)::QueryContext
    method_inventory_hash(runtime)
    Threads.atomic_add!(context.frame_runs, 1)
    edges = frame_edges(context.mode, signature, context.scope)
    for method in edges.methods
        path = tracked_path(context.placements, method)
        if haskey(context.placements.files, path)
            source_code_hash(runtime, path)
        end
    end
    for callee in edges.callees
        context.signatures[type_key(callee)] = callee
    end
    return frame_record(context.placements, edges)
end

"""Collect all frames reachable from one compiled testset body."""
@derived function testset_reach(runtime::Salsa.Runtime, name::String, signature::Type)::ReachResult
    context = Salsa.context(runtime)::QueryContext
    testset_code_hash(runtime, name)
    Threads.atomic_add!(context.reach_runs, 1)
    root_key = type_key(signature)
    context.signatures[root_key] = signature
    pending = Set{String}([root_key])
    seen = Set{String}()
    positions = Set{Int}()
    unresolved = Set{String}()
    unmapped = Set{String}()
    everything = false
    while !isempty(pending)
        key = first(pending)
        pending = setdiff(pending, Set{String}([key]))
        if key in seen
            continue
        end
        record = reached_frame(runtime, context.signatures[key])
        seen = union(seen, Set{String}([key]))
        pending = union(pending, Set{String}(record.callees))
        positions = union(positions, Set{Int}(record.positions))
        unresolved = union(unresolved, Set{String}(record.unresolved))
        unmapped = union(unmapped, Set{String}(record.unmapped))
        everything = everything || record.everything
    end
    return ReachResult(positions, seen, unresolved, unmapped, everything)
end

"""Recover frame signatures from serialized Salsa dependency keys."""
function cached_signatures(storage::Salsa.DefaultStorage)::Dict{String, Type}
    _, derived = Salsa.Inspect.all_inputs_and_derived_vals(storage)
    signatures = Dict{String, Type}()
    for key in keys(derived)
        if key isa Salsa.DerivedKey{typeof(reached_frame)}
            signature = only(key.args)::Type
            signatures[type_key(signature)] = signature
        end
    end
    return signatures
end
