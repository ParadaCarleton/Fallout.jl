using .InferenceWalk: builtin_callee, invoked_instance, logging_call, mentions_module

"""What a walk does at an unresolved call site: drop the edge and count it."""
struct DropUnresolved end

"""What a walk does at an unresolved call site: follow every method in scope that can match a known callee."""
struct FollowKnown end

"""What a walk does at an unresolved call site: follow every method that can match, and reach all source from an unknown callee."""
struct FollowUnresolved end

const WalkMode = Union{DropUnresolved, FollowKnown, FollowUnresolved}

"""
The modules and directories whose methods the walk follows. `outside` indexes methods
defined on external functions by scope type. `owned` indexes them by function owner.
"""
struct Scope
    modules::Vector{Module}
    directories::Vector{String}
    outside::Dict{Core.TypeName, Vector{Type}}
    owned::Dict{Module, Vector{Type}}
end

function Scope(modules::AbstractVector{Module}, directories::AbstractVector{String})::Scope
    collector = OutsideCollector(modules, Dict{Core.TypeName, Vector{Type}}(), Dict{Module, Vector{Type}}())
    Base.visit(collector, Core.methodtable)
    return Scope(Vector{Module}(modules), Vector{String}(directories), collector.found, collector.owned)
end

"""Collects, from `Base.visit` over the method table, the `outside` and `owned` indexes of a `Scope` of `modules`."""
struct OutsideCollector
    modules::Vector{Module}
    found::Dict{Core.TypeName, Vector{Type}}
    owned::Dict{Module, Vector{Type}}
end

"""
The module owning the function a method of type `function_type` belongs to: the type's module
for a constructor (`Base.IndexStyle(::Type{<:T})` belongs to Base), else the function's.
"""
function function_owner(function_type::DataType)::Module
    if !(function_type <: Type) || isempty(function_type.parameters)
        return parentmodule(function_type)
    end
    constructed = function_type.parameters[1]
    if constructed isa TypeVar
        constructed = constructed.ub
    end
    body = Base.unwrap_unionall(constructed)
    if body isa DataType
        return parentmodule(body)
    end
    return Core
end

"""Index `method` when it is a scope method of a function or a constructor owned outside the scope."""
function (collector::OutsideCollector)(method::Method)::Nothing
    signature = Base.unwrap_unionall(method.sig)
    if !in_modules(collector.modules, method.module) || !(signature isa DataType) || isempty(signature.parameters)
        return nothing
    end
    function_type = constructor_head(Base.unwrap_unionall(signature.parameters[1]))
    if !(function_type isa DataType) || in_modules(collector.modules, function_owner(function_type))
        return nothing
    end
    names = Set{Core.TypeName}()
    arguments = signature.parameters[2:end]
    if function_type === typeof(Core.kwcall) && length(signature.parameters) >= 3
        arguments = signature.parameters[3:3]
    end
    for parameter in arguments
        scope_type_names!(names, collector.modules, parameter, 0)
    end
    functions = Set{Core.TypeName}(name for name in names if name.wrapper <: Function)
    if !isempty(functions)
        names = functions
    end
    direct = Set{Core.TypeName}()
    for parameter in arguments
        scope_type_names!(direct, collector.modules, parameter, 8)
    end
    if isempty(functions) && !isempty(direct)
        names = direct
    end
    if isempty(names) && function_type === typeof(Core.kwcall) && length(signature.parameters) >= 3
        callee_body = Base.unwrap_unionall(signature.parameters[3])
        if callee_body isa DataType
            union!(names, Set{Core.TypeName}([callee_body.name]))
        end
    end
    if isempty(names)
        union!(names, Set{Core.TypeName}([function_type.name]))
        owner = Base.moduleroot(function_owner(function_type))
        collector.owned[owner] = vcat(get(collector.owned, owner, Type[]), Type[method.sig])
    end
    for name in names
        collector.found[name] = vcat(get(collector.found, name, Type[]), Type[method.sig])
    end
    return nothing
end

"""Normalize a callable signature's type head."""
constructor_head(type::Any)::Any = type

"""
Add scope types named by `type` through parameters and type bounds, to depth eight.
"""
function scope_type_names!(names::Set{Core.TypeName}, modules::AbstractVector{Module}, type::Any, depth::Int)::Nothing
    if depth > 8
        return nothing
    end
    if type isa TypeVar
        scope_type_names!(names, modules, type.ub, depth)
        return nothing
    end
    if type isa Union
        for member in Base.uniontypes(type)
            scope_type_names!(names, modules, member, depth)
        end
        return nothing
    end
    body = if type isa UnionAll
        Base.unwrap_unionall(type)
    else
        type
    end
    if !(body isa DataType)
        if body !== type
            scope_type_names!(names, modules, body, depth)
        end
        return nothing
    end
    if in_modules(modules, body.name.module)
        union!(names, Set{Core.TypeName}([body.name]))
    end
    for parameter in body.parameters
        scope_type_names!(names, modules, parameter, depth + 1)
    end
    return nothing
end

"""What one frame's IR calls: methods reached, signatures to walk next, one label per unresolved site."""
struct FrameEdges
    methods::Vector{Method}
    callees::Vector{Type}
    unresolved::Vector{String}
    everything::Bool
end

"""What one call site leads to: the scope methods it dispatches to, the frames to walk, and whether it was left unresolved or reaches anything."""
struct SiteEdges
    methods::Vector{Method}
    callees::Vector{Type}
    unresolved::Bool
    unknown::Bool
end

"""Whether `candidate` is one of `modules` or lies inside one."""
function in_modules(modules::AbstractVector{Module}, candidate::Module)::Bool
    if candidate in modules
        return true
    end
    parent = parentmodule(candidate)
    if parent === candidate
        return false
    end
    return in_modules(modules, parent)
end

"""The type a statement's value is known to have, as a `Type`."""
widened(type::Type)::Type = type
widened(type::Core.PartialStruct)::Type = type.typ
widened(::Any)::Type = Any
function widened(type::Core.Const)::Type
    return typeof_value(type.val)
end

"""The type a value of a call site's argument has: `Type{value}` for a type, so constructors dispatch."""
typeof_value(value::Type)::Type = Type{value}
typeof_value(value::Any)::Type = typeof(value)

function value_type(code::Core.CodeInfo, value::Core.SSAValue)::Type
    if code.ssavaluetypes isa Vector
        return widened(code.ssavaluetypes[value.id])
    end
    return Any
end
function value_type(code::Core.CodeInfo, value::Core.Argument)::Type
    if code.slottypes isa Vector
        return widened(code.slottypes[value.n])
    end
    return Any
end

function value_type(code::Core.CodeInfo, value::Core.SlotNumber)::Type
    if code.slottypes isa Vector
        return widened(code.slottypes[value.id])
    end
    return Any
end

function value_type(::Core.CodeInfo, value::GlobalRef)::Type
    if Base.invokelatest(isdefined, value.mod, value.name)
        return typeof_value(Base.invokelatest(getglobal, value.mod, value.name))
    end
    return Any
end

value_type(::Core.CodeInfo, value::QuoteNode)::Type = typeof_value(value.value)
value_type(::Core.CodeInfo, value::Any)::Type = typeof_value(value)

"""A callee name for the report."""
callee_label(called::GlobalRef)::String = string(called.mod, ".", called.name)
callee_label(::Core.SSAValue)::String = "a computed callee"
callee_label(::Union{Core.Argument, Core.SlotNumber})::String = "a callee argument"
callee_label(called::Any)::String = string(called)

"""Whether `type` is the type of a closure (anonymous, named inner or keyword body), not of a generic function."""
function closure_type(type::DataType)::Bool
    name = String(type.name.name)
    return startswith(name, '#') && (count('#', name) >= 2 || all(isdigit, name[2:end]))
end

"""Whether `statement` splats its arguments into the call of its third argument."""
function splat_call(statement::Expr)::Bool
    called = first(statement.args)
    if called isa GlobalRef
        return isdefined(called.mod, called.name) && getglobal(called.mod, called.name) === Core._apply_iterate
    end
    return called === Core._apply_iterate
end

"""The functions that run code chosen at run time: `invokelatest` and `eval` and the builtins they inline to."""
const RUNTIME_CALLEES = Tuple(
    vcat(
        Any[Base.invokelatest],
        Any[getglobal(Core, name) for name in (:eval, :_call_latest, :_call_in_world, :_call_in_world_total) if isdefined(Core, name)],
    )
)

"""Whether a callee is a function value inference cannot know: `invokelatest` and `eval` run code chosen at run time."""
function runtime_callee(called::Any)::Bool
    return called in RUNTIME_CALLEES
end
function runtime_callee(called::GlobalRef)::Bool
    return isdefined(called.mod, called.name) && runtime_callee(getglobal(called.mod, called.name))
end

"""The methods that can match `signature`, or `nothing` when the method table cannot say."""
function matching_methods(signature::Type)::Union{Nothing, Vector{Core.MethodMatch}}
    return method_matches(Base._methods_by_ftype(signature, -1, Base.get_world_counter()))
end

"""Normalize the compiler's method-table result."""
method_matches(matches::Vector)::Vector{Core.MethodMatch} = Core.MethodMatch[match for match in matches]
method_matches(::Any)::Nothing = nothing

"""
Whether a callee of type `type` names the methods it can run: a concrete type, or one whose
every member is a type of the scope, or the constructor of one, with parameters unknown (a
callable struct read from an abstractly typed field, `FieldDuels{E}` for a runtime `E`). `Any`
and `Function` name nothing.
"""
function known_callee(scope::Scope, type::Type)::Bool
    if type === Union{}
        return false
    end
    if Base.isdispatchtuple(Tuple{type})
        return true
    end
    members = Base.uniontypes(type)
    for member in members
        body = Base.unwrap_unionall(member)
        if !(body isa DataType) || body === Any || !in_modules(scope.modules, function_owner(body))
            return false
        end
    end
    return true
end

"""
The types of the elements of a splatted `value`: the arguments of the `Core.svec` that builds it (how
inference passes a keyword call's keywords and function), or the parameters of its tuple type; none when unknown.
"""
function splatted_types(code::Core.CodeInfo, value::Core.SSAValue)::Vector{Type}
    built = code.code[value.id]
    if built isa Expr && built.head === :call && (first(built.args) === Core.svec || (first(built.args) isa GlobalRef && first(built.args) == GlobalRef(Core, :svec)))
        return Type[value_type(code, argument) for argument in built.args[2:end]]
    end
    return splatted_types(value_type(code, value))
end
splatted_types(code::Core.CodeInfo, value::Any)::Vector{Type} = splatted_types(value_type(code, value))
function splatted_types(type::Type)::Vector{Type}
    body = Base.unwrap_unionall(type)
    if body isa DataType && body <: Tuple && !any(Base.isvarargtype, body.parameters)
        return Type[parameter for parameter in body.parameters]
    end
    return Type[]
end

"""
    site_edges(mode, code, statement, scope)

What the `:call` `statement` of `code` leads to. A site whose callee and arguments are all
concrete types dispatches to the methods of exactly that signature; any other site is
unresolved.
"""
function site_edges(mode::WalkMode, code::Core.CodeInfo, statement::Expr, scope::Scope)::SiteEdges
    splat = splat_call(statement)
    called = if splat
        statement.args[3]
    else
        first(statement.args)
    end
    callee_type = value_type(code, called)
    if runtime_callee(called) || !known_callee(scope, callee_type)
        return SiteEdges(Method[], Type[], true, true)
    end
    if callee_type === typeof(Core.kwcall) && !splat && (length(statement.args) < 3 || !known_callee(scope, value_type(code, statement.args[3])))
        return SiteEdges(Method[], Type[], true, true)
    end
    argument_types = if splat
        Type[]
    else
        Type[value_type(code, argument) for argument in statement.args[2:end]]
    end
    signature = if splat
        Tuple{callee_type, Vararg{Any}}
    else
        Tuple{callee_type, argument_types...}
    end
    if splat && callee_type === typeof(Core.kwcall)
        leading = if length(statement.args) >= 4
            splatted_types(code, statement.args[4])
        else
            Type[]
        end
        if length(leading) < 2 || !known_callee(scope, leading[2])
            return SiteEdges(Method[], Type[], true, true)
        end
        signature = Tuple{callee_type, leading..., Vararg{Any}}
    end
    matches = matching_methods(signature)
    return matched_site_edges(matches, scope, !splat && Base.isdispatchtuple(signature), mode)
end

"""Convert method matches to a dynamic call site's reach edges."""
function matched_site_edges(matches::Union{Nothing, Vector{Core.MethodMatch}}, scope::Scope, resolved::Bool, mode::WalkMode)::SiteEdges
    if isnothing(matches)
        return SiteEdges(Method[], Type[], true, true)
    end
    in_scope = Core.MethodMatch[match for match in matches if in_modules(scope.modules, match.method.module)]
    if resolved || mode isa Union{FollowKnown, FollowUnresolved}
        return SiteEdges(Method[match.method for match in in_scope], Type[match.spec_types for match in in_scope], false, false)
    end
    return SiteEdges(Method[], Type[], !isempty(in_scope), false)
end

"""
Whether values of `type` may be called by code the IR does not show (a task, a `tmap`, a root
finder): a closure, or a scope type with call methods. Its parameters may be unknown, as when a
frame walked at abstract argument types builds a callable struct: its call methods are walked
at those abstract types.
"""
function callable_type(scope::Scope, type::Type)::Bool
    body = Base.unwrap_unionall(type)
    if !(body isa DataType) || type <: Type || body === Any
        return false
    end
    if closure_type(body)
        return true
    end
    if !in_modules(scope.modules, parentmodule(body))
        return false
    end
    matches = matching_methods(Tuple{type, Vararg{Any}})
    return !isnothing(matches) && !isempty(matches)
end

"""
Find values passed to external code or returned by the frame. External code may call
methods defined in scope on those values.
"""
function escaping_types(code::Core.CodeInfo, statements::AbstractVector{Expr}, scope::Scope)::Vector{Type}
    passed = Type[type for statement in statements if outside_site(code, statement, scope) for type in handed_types(code, statement)]
    returned = Type[value_type(code, statement.val) for statement in code.code if statement isa Core.ReturnNode && isdefined(statement, :val)]
    return unique(vcat(passed, returned))
end

"""
The Base functions that build a container from what they are handed and call only the function
they are handed (the one inside a `Generator`), never a value the container holds.
"""
const CONTAINER_BUILDERS = (:merge, :pairs, :collect)

"""Whether `statement` calls one of `CONTAINER_BUILDERS`."""
container_site(code::Core.CodeInfo, statement::Expr)::Bool = base_site(code, statement, CONTAINER_BUILDERS)

"""
The Base and compiler functions that take a function and argument types and only look the method up
or infer it, never calling the function: the type of a `memo_types` memo is inferred this way
from the filing solve's own functions.
"""
const TYPE_INSPECTORS = (:return_type, :return_types, :promote_op, :hasmethod, :applicable, :code_typed, :code_lowered, :which, :methods)

"""Whether `statement` calls one of `TYPE_INSPECTORS`."""
type_inspection_site(code::Core.CodeInfo, statement::Expr)::Bool = base_site(code, statement, TYPE_INSPECTORS)

"""Whether `statement` calls a function of Base (or its compiler) named in `names`."""
function base_site(code::Core.CodeInfo, statement::Expr, names::Tuple)::Bool
    if statement.head === :invoke
        instance = invoked_instance(first(statement.args))
        return instance isa Core.MethodInstance && instance.def isa Method && instance.def.module in (Base, Core.Compiler) && instance.def.name in names
    end
    body = Base.unwrap_unionall(value_type(code, first(statement.args)))
    return statement.head === :call && body isa DataType && function_owner(body) in (Base, Core.Compiler) && Symbol(lstrip(String(body.name.name), '#')) in names
end

"""The closure types `type` names through its parameters, down to depth 8."""
function closure_parameters(type::Any, depth::Int)::Vector{Type}
    body = Base.unwrap_unionall(type)
    if depth > 8 || !(body isa DataType)
        return Type[]
    end
    own = if closure_type(body)
        Type[type]
    else
        Type[]
    end
    return vcat(own, reduce(vcat, (closure_parameters(parameter, depth + 1) for parameter in body.parameters); init = Type[]))
end

"""
Find closure types created by a frame, including closures whose captured types widen.
"""
function created_closures(code::Core.CodeInfo)::Vector{Type}
    created = Type[value_type(code, Core.SSAValue(index)) for (index, statement) in enumerate(code.code) if statement isa Expr && statement.head === :new]
    return Type[type for type in created if Base.unwrap_unionall(type) isa DataType && closure_type(Base.unwrap_unionall(type))]
end

"""The types of the values `statement` hands to outside code that can be called back: all of them, but for a container builder only its closures, and for a type inspector none."""
function handed_types(code::Core.CodeInfo, statement::Expr)::Vector{Type}
    if type_inspection_site(code, statement)
        return Type[]
    end
    types = Type[value_type(code, argument) for argument in site_arguments(statement)]
    if container_site(code, statement)
        return reduce(vcat, (closure_parameters(type, 0) for type in types); init = Type[])
    end
    return types
end

"""
The types of the values a frame stores in a captured variable that a closure reassigns or defines after use
(a `Core.Box`): a closure reads the box, whose content type no IR shows (`@check`'s `run` calls the
property function it names through one), so a callable stored there runs where the box is read.
"""
function boxed_types(code::Core.CodeInfo, statements::AbstractVector{Expr})::Vector{Type}
    stores = Expr[statement for statement in statements if statement.head === :call && length(statement.args) == 4 && store_callee(first(statement.args))]
    return unique(Type[value_type(code, last(statement.args)) for statement in stores if value_type(code, statement.args[2]) === Core.Box])
end

"""Whether `called` is `Core.setfield!`, as a function value or a reference to it."""
store_callee(called::GlobalRef)::Bool = called.name === :setfield! && called.mod === Core
store_callee(called::Any)::Bool = called === Core.setfield!

"""The arguments a call passes to its callee."""
function site_arguments(statement::Expr)::Vector{Any}
    if splat_call(statement)
        return Any[statement.args[4:end]...]
    end
    if statement.head === :call
        return Any[statement.args[2:end]...]
    end
    return Any[statement.args[3:end]...]
end

"""
Whether a statement calls code outside the scope: an `:invoke` of an outside method, or a
`:call` of a function the scope does not own. A splat or keyword call is judged by the
function it calls; `invokelatest`'s builtin runs code chosen at run time, so it is outside;
another builtin calls nothing.
"""
function outside_site(code::Core.CodeInfo, statement::Expr, scope::Scope)::Bool
    if statement.head in (:invoke, :invoke_modify)
        instance = invoked_instance(first(statement.args))
        return instance isa Core.MethodInstance && instance.def isa Method && !in_modules(scope.modules, instance.def.module)
    end
    if statement.head !== :call
        return false
    end
    called = first(statement.args)
    if splat_call(statement) || value_type(code, called) === typeof(Core.kwcall)
        called = statement.args[3]
    elseif builtin_callee(called) && !runtime_callee(called)
        return false
    end
    body = Base.unwrap_unionall(value_type(code, called))
    return !(body isa DataType) || body === Any || !in_modules(scope.modules, function_owner(body))
end

"""
Find callable values among `types` and callable scope types named by their parameters.
"""
function callable_seeds(types::AbstractVector{Type}, scope::Scope)::Vector{Type}
    names = Set{Core.TypeName}()
    for type in types
        scope_type_names!(names, scope.modules, type, 0)
    end
    nested = reduce(vcat, (closure_parameters(type, 0) for type in types); init = Type[])
    candidates = vcat(types, nested, Type[name.wrapper for name in names])
    return unique(Type[Tuple{type, Vararg{Any}} for type in candidates if callable_type(scope, type)])
end

"""The scope's methods of outside functions (`Scope`'s `outside`) on a scope type that `types` name."""
function outside_seeds(types::AbstractVector{Type}, scope::Scope)::Vector{Type}
    names = Set{Core.TypeName}()
    for type in types
        scope_type_names!(names, scope.modules, type, 0)
        body = Base.unwrap_unionall(type)
        if body isa DataType
            union!(names, Set{Core.TypeName}([body.name]))
        end
    end
    return unique(reduce(vcat, (get(scope.outside, name, Type[]) for name in names); init = Type[]))
end

"""The optimized IR of every method `signature` matches, with the debug info that names what was inlined, or none when inference cannot type it."""
function typed_frames(signature::Type)::Vector{Any}
    return try
        Base.code_typed_by_type(signature; optimize = true, debuginfo = :source)
    catch
        Any[]
    end
end

"""The method a frame's debug info or instance names, as a vector of zero or one."""
definition_methods(info::Core.MethodInstance)::Vector{Method} = definition_methods(info.def)
definition_methods(info::Core.CodeInstance)::Vector{Method} = definition_methods(info.def)
definition_methods(info::Method)::Vector{Method} = Method[info]
definition_methods(::Any)::Vector{Method} = Method[]

"""Every method a frame's debug info says was compiled into it: the frame's own and each inlined callee's."""
function debuginfo_methods(info::Core.DebugInfo)::Vector{Method}
    nested = Any[edge for edge in info.edges]
    if info.linetable isa Core.DebugInfo
        nested = vcat(nested, Any[info.linetable])
    end
    return vcat(definition_methods(info.def), reduce(vcat, (debuginfo_methods(edge) for edge in nested if edge isa Core.DebugInfo); init = Method[]))
end

"""Follow a invoked method when it may call code in scope."""
function traversable_instance(instance::Core.MethodInstance, scope::Scope)::Bool
    if in_modules(scope.modules, instance.def.module)
        return true
    end
    if instance.def.name in CONTAINER_BUILDERS
        return false
    end
    return any(target -> mentions_module(instance.specTypes, target, 0), scope.modules)
end

"""
What the optimized IR `code` calls: its methods (its own, the inlined and the `:invoke` targets),
the frames to walk and its unresolved sites. A site is a `:call` that survived optimization.
"""
function code_edges(mode::WalkMode, code::Core.CodeInfo, scope::Scope)::FrameEdges
    statements = Expr[statement for statement in code.code if statement isa Expr]
    instances = [invoked_instance(first(statement.args)) for statement in statements if statement.head in (:invoke, :invoke_modify)]
    invoked = Core.MethodInstance[instance for instance in instances if instance isa Core.MethodInstance && instance.def isa Method]
    sites = Expr[
        statement for statement in statements
            if statement.head === :call && (splat_call(statement) || runtime_callee(first(statement.args)) || (!builtin_callee(first(statement.args)) && !logging_call(statement)))
    ]
    outcomes = SiteEdges[site_edges(mode, code, site, scope) for site in sites]
    methods = vcat(
        definition_methods(code.parent), debuginfo_methods(code.debuginfo), Method[instance.def for instance in invoked],
        reduce(vcat, (outcome.methods for outcome in outcomes); init = Method[]),
    )
    seen = escaping_types(code, statements, scope)
    ran = Type[type for type in (function_type(method) for method in methods) if type <: Function && type !== typeof(Core.kwcall)]
    callees = vcat(
        Type[instance.specTypes for instance in invoked if traversable_instance(instance, scope)],
        reduce(vcat, (outcome.callees for outcome in outcomes); init = Type[]),
        callable_seeds(vcat(seen, boxed_types(code, statements), created_closures(code)), scope),
        outside_seeds(unique(vcat(seen, ran)), scope),
        owned_seeds(definition_methods(code.parent), scope),
    )
    labels = String[
        callee_label(
            if splat_call(site)
                site.args[3]
            else
                first(site.args)
            end
        ) for (site, outcome) in zip(sites, outcomes) if outcome.unresolved
    ]
    return FrameEdges(unique(methods), unique(callees), labels, any(outcome -> outcome.unknown && mode isa FollowUnresolved, outcomes))
end

"""The type of the function `method` belongs to, a type variable's bound for a method of `(::T)(…) where T`."""
function function_type(method::Method)::Type
    return function_type_head(Base.unwrap_unionall(method.sig).parameters[1])
end

"""Resolve a callable's function type from its method signature."""
function_type_head(type::Type)::Type = type
function_type_head(type::TypeVar)::Type = type.ub

"""The scope's methods naming no scope type of functions the package of a frame's `methods` owns (`Scope`'s `owned`)."""
function owned_seeds(methods::AbstractVector{Method}, scope::Scope)::Vector{Type}
    return unique(reduce(vcat, (get(scope.owned, Base.moduleroot(method.module), Type[]) for method in methods); init = Type[]))
end

"""What one `code_typed_by_type` entry calls: its IR's edges, or just its method when inference returned no IR."""
entry_edges(mode::WalkMode, code::Core.CodeInfo, scope::Scope)::FrameEdges = code_edges(mode, code, scope)
entry_edges(::WalkMode, method::Method, ::Scope)::FrameEdges = FrameEdges(Method[method], Type[], String[], false)
entry_edges(::WalkMode, ::Any, ::Scope)::FrameEdges = FrameEdges(Method[], Type[], String[], false)

"""The call a statement of unoptimized IR makes: the statement, or the right side of a slot assignment."""
function assigned_call(statement::Expr)::Expr
    if statement.head === :(=) && statement.args[2] isa Expr
        return statement.args[2]
    end
    return statement
end

"""Whether an unoptimized statement calls a function other than a builtin."""
function call_statement(statement::Any)::Bool
    if !(statement isa Expr)
        return false
    end
    call = assigned_call(statement)
    return call.head === :call && !builtin_callee(first(call.args))
end

"""
Whether inference marked an unoptimized statement unreachable.
"""
dead_statement(statement::Any, type::Any)::Bool = statement isa Core.Const && type === Union{} && statement.val isa Union{Expr, GlobalRef}

"""
Whether an unoptimized statement of inferred type `type` makes a call the optimizer drops:
inference found its value constant, or never reached it.
"""
function dropped_call(statement::Any, type::Any)::Bool
    if dead_statement(statement, type)
        return call_statement(statement.val)
    end
    return type isa Core.Const && call_statement(statement)
end

"""
`code` with its dead statements unwrapped, a dead callee read as the value its global names and
any other dead value, or slot assigned only in dead code (typed `Union{}`), as `Any`, so the
calls of a dead branch resolve as far as their live arguments and named callees allow.
"""
function revived(code::Core.CodeInfo)::Core.CodeInfo
    live = copy(code)
    live.code = Any[revived_statement(statement, type) for (statement, type) in zip(code.code, code.ssavaluetypes)]
    live.ssavaluetypes = Any[revived_type(code, statement, type) for (statement, type) in zip(code.code, code.ssavaluetypes)]
    if code.slottypes isa Vector
        live.slottypes = Any[ifelse(type === Union{}, Any, type) for type in code.slottypes]
    end
    return live
end

"""A dead statement unwrapped, any other as it is."""
function revived_statement(statement::Any, type::Any)::Any
    if dead_statement(statement, type)
        return statement.val
    end
    return statement
end

"""
A dead global's value type, `Any` for any other dead statement or one that never returns (a
dead call may read it), a live statement's inferred type otherwise.
"""
function revived_type(code::Core.CodeInfo, statement::Any, type::Any)::Any
    if dead_statement(statement, type) && statement.val isa GlobalRef
        return value_type(code, statement.val)
    end
    if dead_statement(statement, type) || type === Union{}
        return Any
    end
    return type
end

"""
A walk frame that reads only the folded and dead calls of signature `S` (`folded_edges`): a
scope function called by name may be inlined, which leaves its live calls in its caller's IR and
its dead branches nowhere. Walking it as a whole frame would also count the values it returns as
handed to outside code, which they are not.
"""
struct FoldedCalls{S} end

"""
What the calls of `signature` that inference folds to a constant or never reaches run, read
from the unoptimized IR: the optimizer replaces a folded call by its value and deletes a dead
branch, keeping no trace of either in the IR or its debug info. Each scope function the frame
calls by name gets a `FoldedCalls` frame, which finds the dead branches of an inlined callee
(a branch past `differentiating()`).
"""
function folded_edges(mode::WalkMode, signature::Type, scope::Scope)::FrameEdges
    typed = try
        Base.code_typed_by_type(signature; optimize = false)
    catch
        Any[]
    end
    codes = Core.CodeInfo[first(entry) for entry in typed if first(entry) isa Core.CodeInfo && first(entry).ssavaluetypes isa Vector]
    statements = [
        (live, statement, type, live_statement)
            for (code, live) in zip(codes, map(revived, codes))
            for (statement, type, live_statement) in zip(code.code, code.ssavaluetypes, live.code)
    ]
    dropped = SiteEdges[site_edges(mode, live, assigned_call(live_statement), scope) for (live, statement, type, live_statement) in statements if dropped_call(statement, type)]
    called = SiteEdges[
        site_edges(mode, live, assigned_call(live_statement), scope)
            for (live, statement, type, live_statement) in statements if !dropped_call(statement, type) && call_statement(statement)
    ]
    return FrameEdges(
        unique(reduce(vcat, (outcome.methods for outcome in vcat(dropped, called)); init = Method[])),
        unique(
            vcat(
                reduce(vcat, (outcome.callees for outcome in dropped); init = Type[]),
                Type[FoldedCalls{callee} for outcome in called for callee in outcome.callees],
            )
        ),
        String[],
        false,
    )
end

frame_edges(mode::WalkMode, @nospecialize(frame::Type{<:FoldedCalls}), scope::Scope)::FrameEdges = folded_edges(mode, only(frame.parameters), scope)

"""What the IR of `signature` calls, folded calls included. A signature inference cannot type counts as one unresolved site."""
function frame_edges(mode::WalkMode, signature::Type, scope::Scope)::FrameEdges
    typed = typed_frames(signature)
    edges = vcat(FrameEdges[entry_edges(mode, first(entry), scope) for entry in typed], FrameEdges[folded_edges(mode, signature, scope)])
    untyped = String[]
    if isempty(typed) && Base.isdispatchtuple(signature)
        untyped = ["an untyped frame"]
    end
    return FrameEdges(
        unique(reduce(vcat, (edge.methods for edge in edges); init = Method[])),
        unique(reduce(vcat, (edge.callees for edge in edges); init = Type[])),
        vcat(untyped, reduce(vcat, (edge.unresolved for edge in edges); init = String[])),
        any(edge -> edge.everything, edges) || (!isempty(untyped) && mode isa FollowUnresolved),
    )
end

if VERSION >= v"1.14.0-alpha2"
    include("static_reach_114.jl")
end
