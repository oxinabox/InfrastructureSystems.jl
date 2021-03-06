import InteractiveUtils

g_cached_subtypes = Dict{DataType, Vector{DataType}}()

"""
Returns an array of all concrete subtypes of T.
Note that this does not find parameterized types.
"""
function get_all_concrete_subtypes(::Type{T}) where {T}
    if haskey(g_cached_subtypes, T)
        return g_cached_subtypes[T]
    end

    sub_types = Vector{DataType}()
    _get_all_concrete_subtypes(T, sub_types)
    g_cached_subtypes[T] = sub_types
    return sub_types
end

"""Recursively builds a vector of subtypes."""
function _get_all_concrete_subtypes(::Type{T}, sub_types::Vector{DataType}) where {T}
    for sub_type in InteractiveUtils.subtypes(T)
        if isconcretetype(sub_type)
            push!(sub_types, sub_type)
        elseif isabstracttype(sub_type)
            _get_all_concrete_subtypes(sub_type, sub_types)
        end
    end

    return nothing
end

"""Returns an array of concrete types that are direct subtypes of T."""
function get_concrete_subtypes(::Type{T}) where {T}
    return [x for x in InteractiveUtils.subtypes(T) if isconcretetype(x)]
end

"""Returns an array of abstract types that are direct subtypes of T."""
function get_abstract_subtypes(::Type{T}) where {T}
    return [x for x in InteractiveUtils.subtypes(T) if isabstracttype(x)]
end

"""Returns an array of all super types of T."""
function supertypes(::Type{T}, types = []) where {T}
    super = supertype(T)
    push!(types, super)
    if super == Any
        return types
    end

    supertypes(super, types)
end

"""Converts a DataType to a Symbol, stripping off the module name(s)."""
function type_to_symbol(data_type::DataType)
    return Symbol(strip_module_name(string(data_type)))
end

"""Strips the module name off of a type."""
function strip_module_name(name::String)
    index = findfirst(".", name)
    # Account for the period being part of a parametric type.
    parametric_index = findfirst("{", name)

    if isnothing(index) ||
       (!isnothing(parametric_index) && index.start > parametric_index.start)
        basename = name
    else
        basename = name[(index.start + 1):end]
    end

    return basename
end

function strip_module_name(::Type{T}) where {T}
    return strip_module_name(string(T))
end

function strip_parametric_type(name::AbstractString)
    index = findfirst("{", name)
    if !isnothing(index)
        # Ignore the parametric type.
        name = name[1:(index.start - 1)]
    end

    return name
end

"""
Return a symbol parsed from a serialized string. Sanitizes the input first and attempts to
ensure that the string does not contain code. The caller can call `eval` on the returned
symbol.

Throws ErrorException if the string contains invalid characters or code.

"""
function parse_serialized_type(serialized_type::Union{Symbol, String})
    if serialized_type isa Symbol
        serialized_type = string(serialized_type)
    end

    _check_expression_characters(serialized_type)
    val = Meta.parse(serialized_type)
    if val isa Symbol
        return val
    elseif val isa Expr
        _check_parametric_expression(val)
    else
        error("invalid type: $val")
    end

    return val
end

function _check_expression_characters(serialized_type::String)
    # This will return false if the char is any symbol or operator other than
    # '{', '}', and ',', which should be the only non-alphanumeric characters allowed
    # in a type that we are handling during serialization (as of now).
    # Look up an ASCII table to interpret these.
    for char in serialized_type
        is_valid = false
        value = codepoint(char)
        if value < 32
            is_valid = false
        elseif value >= 33 && value <= 47 && value != 44
            is_valid = false
        elseif value >= 58 && value <= 64
            is_valid = false
        elseif value >= 91 && value <= 94
            is_valid = false
        elseif value == 96 || value == 124 || value == 126
            is_valid = false
        elseif value == 124
            is_valid = false
        else
            is_valid = true
        end

        if !is_valid
            error("$char is not allowed in $serialized_type")
        end
    end
end

function _check_parametric_expression(expr::Expr)
    # Recursively check the expression to make sure it only contains :curly and Symbols.
    if expr.head != :curly
        error("invalid expr: $expr")
    end

    for arg in expr.args
        if arg isa Symbol
            continue
        elseif arg isa Expr
            _check_parametric_expression(arg)
        else
            error("invalid expr: $arg")
        end
    end
end

"""Converts an object deserialized from JSON into a Julia type, such as NamedTuple,
to an instance of T. Similar to Base.convert, but not a viable replacement.
"""
function convert_type(::Type{T}, data::Any) where {T}
    # Improvement: implement the conversion logic. Need to recursively convert fieldnames
    # to fieldtypes, collect the values, and pass them to T(). Also handle literals.
    # The JSON2 library already handles almost all of the cases.
    #if data isa AbstractString && T <: AbstractString
    if T <: AbstractString
        return T(data)
    end
    return JSON2.read(JSON2.write(data), T)
end

"""
Return true if all publicly exported names in mod are defined.
"""
function validate_exported_names(mod::Module)
    is_valid = true
    for name in names(mod)
        if !isdefined(mod, name)
            is_valid = false
            @error "module $mod exports $name but does not define it"
        end
    end

    return is_valid
end

"""
Recursively compares struct values by performing == on each field in the struct.
When performing == on values of immutable structs Julia will perform === on
each field.  This will return false if any field is mutable even if the
contents are the same.  So, comparison of any InfrastructureSystems type with an array
will fail.

This is an unresolved Julia issue. Refer to
https://github.com/JuliaLang/julia/issues/4648.

An option is to overload == for all subtypes of PowerSystemType. That may not be
appropriate in all cases. Until the Julia developers decide on a solution, this
function is provided for convenience for specific comparisons.

"""
function compare_values(x::T, y::T)::Bool where {T}
    match = true
    fields = fieldnames(T)
    if isempty(fields)
        match = x == y
    else
        for fieldname in fields
            if T <: Forecasts && fieldname == :time_series_storage
                # This gets validated at SystemData. Don't repeat for each component.
                continue
            end
            val1 = getfield(x, fieldname)
            val2 = getfield(y, fieldname)
            if !isempty(fieldnames(typeof(val1)))
                if !compare_values(val1, val2)
                    @debug "values do not match" T fieldname val1 val2
                    match = false
                    break
                end
            elseif val1 isa AbstractArray
                if !compare_values(val1, val2)
                    match = false
                end
            else
                if val1 != val2
                    @debug "values do not match" T fieldname val1 val2
                    match = false
                    break
                end
            end
        end
    end

    return match
end

function compare_values(x::Vector{T}, y::Vector{T})::Bool where {T}
    if length(x) != length(y)
        @debug "lengths do not match" T length(x) length(y)
        return false
    end

    for i in range(1, length = length(x))
        if !compare_values(x[i], y[i])
            @debug "values do not match" typeof(x[i]) i x[i] y[i]
            return false
        end
    end

    return true
end

function compare_values(x::Dict, y::Dict)::Bool
    keys_x = Set(keys(x))
    keys_y = Set(keys(y))
    if keys_x != keys_y
        @debug "keys don't match" keys_x keys_y
        return false
    end

    for key in keys_x
        if !compare_values(x[key], y[key])
            @debug "values do not match" typeof(x[key]) key x[key] y[key]
            return false
        end
    end

    return true
end

function compare_values(x::T, y::U)::Bool where {T, U}
    # This is a catch-all for where where the types may not be identical but are close
    # enough.
    return x == y
end

"""
Macro to wrap Enum in a baremodule to keep the top level scope clean.
The macro name should be singular. The macro will create a module for access that is plural.

# Examples
```julia
@scoped_enum Fruit begin
    APPLE
    ORANGE
end

value = Fruits.APPLE

# Usage as a function parameter
foo(value::Fruits.Fruit) = nothing
```

"""
macro scoped_enum(T, args...)
    blk = esc(:(baremodule $(Symbol("$(T)s"))
    using Base: @enum
    @enum $T $(args...)
    end))
    return blk
end

function compose_function_delegation_string(
    sender_type::String,
    sender_symbol::String,
    argid::Vector{Int},
    method::Method,
)
    s = "p" .* string.(1:(method.nargs - 1))
    s .*= "::" .* string.(fieldtype.(Ref(method.sig), 2:(method.nargs)))
    s[argid] .= "p" .* string.(argid) .* "::$sender_type"

    m = string(method.module.eval(:(parentmodule($(method.name))))) * "."
    l = "$m:(" * string(method.name) * ")(" * join(s, ", ")

    m = string(method.module) * "."
    l *= ") = $m:(" * string(method.name) * ")("
    s = "p" .* string.(1:(method.nargs - 1))

    s[argid] .= "getfield(" .* s[argid] .* ", :$sender_symbol)"
    l *= join(s, ", ") * ")"
    l = join(split(l, "#"))
    return l
end

function forward(sender::Tuple{Type, Symbol}, receiver::Type, method::Method)
    # Assert that function is always just one argument
    @assert method.nargs < 4 "`forward` only works for one and two argument functions"
    # Assert that function name always starts with `get_*`
    "`forward` only works for accessor methods that are defined as `get_*` or `set_*`"
    @assert startswith(string(method.name), r"set_|get_")
    sender_type = "$(parentmodule(sender[1])).$(nameof(sender[1]))"
    sender_symbol = string(sender[2])
    code_array = Vector{String}()
    # Search for receiver type in method arguments
    argtype = fieldtype(method.sig, 2)
    (sender[1] == argtype) && (return code_array)
    if string(method.name)[1] == '@'
        @warn "Forwarding macros is not yet supported."
        display(method)
        println()
        return code_array
    end

    # first argument only
    push!(
        code_array,
        compose_function_delegation_string(sender_type, sender_symbol, [1], method),
    )

    tmp = split(string(method.module), ".")[1]
    code =
        "@eval " .* tmp .* " " .* code_array .* " # " .* string(method.file) .* ":" .*
        string(method.line)
    if (tmp != "Base") && (tmp != "Main")
        pushfirst!(code, "using $tmp")
    end
    code = unique(code)
    return code
end

function forward(sender::Tuple{Type, Symbol}, receiver::Type)
    code = Vector{String}()
    active_methods = getfield.(InteractiveUtils.methodswith(sender[1]), :name)
    for m in InteractiveUtils.methodswith(receiver)
        m.name ∈ active_methods && continue
        if startswith(string(m.name), "get_") && m.nargs == 2
            # forwarding works for functions with 1 argument and starts with `get_`
            append!(code, forward(sender, receiver, m))
        elseif startswith(string(m.name), "set_") && m.nargs == 3
            # forwarding works for functions with 2 argument and starts with `set_`
            append!(code, forward(sender, receiver, m))
        end
    end
    return code
end

macro forward(sender, receiver)
    out = quote
        list = InfrastructureSystems.forward($sender, $receiver)
        for line in list
            eval(Meta.parse("$line"))
        end
    end
    return esc(out)
end
