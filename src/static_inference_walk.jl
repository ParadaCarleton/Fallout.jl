module InferenceWalk

"""
    mentions_module(signature, target, depth)

Whether `signature` names a type defined in `target` anywhere in its parameters.
"""
function mentions_module(signature::Any, target::Module, depth::Integer)::Bool
    if depth > 6
        return false
    elseif signature isa UnionAll
        return mentions_module(signature.body, target, depth + 1)
    elseif signature isa Union
        return mentions_module(signature.a, target, depth + 1) ||
            mentions_module(signature.b, target, depth + 1)
    elseif !(signature isa DataType)
        return false
    end
    return parentmodule(signature) === target ||
        any(parameter -> mentions_module(parameter, target, depth + 1), signature.parameters)
end

"""
    builtin_callee(called)

Whether a `:call` statement's callee is a builtin or an intrinsic, which keep the
`:call` head after optimization without dispatching. They appear inline or as a `GlobalRef`.
"""
builtin_callee(called::Any)::Bool = called isa Core.Builtin || called isa Core.IntrinsicFunction
builtin_callee(called::GlobalRef)::Bool =
    isdefined(called.mod, called.name) && builtin_callee(getglobal(called.mod, called.name))

"""
    invoked_instance(callee)

The method instance an `:invoke` statement names: a `CodeInstance` on Julia 1.12 and later.
"""
invoked_instance(callee::Core.MethodInstance)::Core.MethodInstance = callee
invoked_instance(callee::Core.CodeInstance)::Union{Nothing, Core.MethodInstance} =
    invoked_instance(callee.def)
invoked_instance(::Any)::Nothing = nothing

"""
    logging_call(statement)

Whether a `:call` statement is a logging macro's hand-off to the current logger, which
is an `AbstractLogger` chosen at runtime and so always dispatches.
"""
logging_call(statement::Expr)::Bool = any(
    argument -> argument isa GlobalRef && argument.mod === Base.CoreLogging ||
        argument === Base.CoreLogging.handle_message,
    statement.args,
)
end
