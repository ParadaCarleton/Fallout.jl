"""Normalize a type equality that denotes a constructor."""
constructor_head(type::Core.TypeEq)::Type = Base.unwrap_unionall(type.T)

"""Add a type equality's constrained type to the scope index."""
function scope_type_names!(names::Set{Core.TypeName}, modules::AbstractVector{Module}, type::Core.TypeEq, depth::Int)::Nothing
    scope_type_names!(names, modules, type.T, depth + 1)
    return nothing
end

"""Resolve a constant global binding embedded in optimized IR."""
function value_type(::Core.CodeInfo, binding::Core.BindingPartition)::Type
    restriction = binding.restriction
    if restriction isa Core.Const
        return widened(restriction)
    end
    return typeof_value(restriction)
end
