module _DefaultSalsaStorage

import ..Salsa
using ..Salsa:
    Runtime, AbstractSalsaStorage, memoized_lookup, invoke_user_function, collect_trace
using ..Salsa: DependencyKey, DerivedKey, InputKey, _storage, RuntimeWithStorage,
    _TopLevelRuntimeWithStorage, _TracingRuntimeWithStorage

import ..Salsa.Debug: @debug_mode, @dbg_log_trace

const Revision = Int

struct InputValue{T}
    value::T
    changed_at::Revision
    # Allow converting from abitrary values (e.g. creating a Vector{String} from []).
    InputValue{T}(v, changed_at) where {T} = new{T}(v, changed_at)
end
InputValue(v::T, changed_at) where {T} = InputValue{T}(v, changed_at)

_changed_at(v::InputValue)::Revision = v.changed_at

# This struct is mutable so that we can edit the Revisions in-place without having to
# reallocate a new DerivedValue. This is a performance optimization to avoid allocations.
# Since this struct contains a Vector, it will not be isbits, so it will be heap-allocated
# anyway (though this may change in the future, with Julia's stack allocation patch in 1.5;
# consider re-evaluating this decision then).
mutable struct DerivedValue{T}
    value::T
    # A list of all the computations that were accessed directly from this derived function
    # (not all recursive dependencies) when computing this derived value.
    dependencies::Vector{DependencyKey}
    # These Revisions are used to determine whether we need to re-compute this value or not.
    # We need both of them in order to correctly implement the Early-Exit Optimization.
    changed_at::Revision
    verified_at::Revision
end

_changed_at(v::DerivedValue)::Revision = v.changed_at



const InputMapType = IdDict{InputKey,Dict}
const DerivedFunctionMapType = IdDict{DerivedKey,Dict}

mutable struct DefaultStorage <: AbstractSalsaStorage
    # The entire Salsa storage is protected by this lock. All accesses and
    # modifications to the storage should be made within this lock.
    lock::Base.ReentrantLock

    # This is bumped every time the storage changes at all, in `set_input!` and
    # `delete_input!`. Whenever this is bumped, we have to check every derived funciton the
    # first time it is called to see if it is still valid.
    # NOTE: This is guaranteed not to change while any derived functions are currently
    # running anywhere on any threads, which we ensure by tracking the count of active
    # derived functions via `derived_functions_active`, below.
    current_revision::Int64

    # We use one big dictionary for the inputs, storing them all together, to reduce
    # allocating a new dictionary for every input.
    # TODO: Do more performance investigation for the tradeoff between sharing a dictionary
    # vs having separate dicts per method. It seems like the current decision is exactly
    # opposite of what would be best: Since DerivedValues are not isbits, they will always
    # be heap allocated, so there's no reason to strongly type their dict. But inputs can
    # be isbits, so it's probably worth specailizing them.
    inputs_map::Dict{Tuple{Type,Tuple},InputValue}
    derived_function_maps::DerivedFunctionMapType

    # Tracks whether there are any derived functions currently active. It is an error to
    # modify any inputs while derived functions are active, on the current Task or any Task.
    derived_functions_active::Int

    function DefaultStorage()
        new(Base.ReentrantLock(), 0, InputMapType(), DerivedFunctionMapType(), 0)
    end
end

const DefaultRuntime = Salsa.Runtime{Salsa.EmptyContext,DefaultStorage}

function Base.show(io::IO, storage::DefaultStorage)
    current_revision = lock(storage.lock) do
        storage.current_revision
    end
    print(io, "Salsa.DefaultStorage($current_revision, ...)")
end


# NOTE: This implements the dynamic behavior for Salsa Components, allowing users to define
# input/derived function dynamically, by attaching new Dicts for them to the storage at
# runtime.
function get_map_for_key(storage::DefaultStorage, key::DerivedKey{<:Any,TT}) where {TT}
    try
        lock(storage.lock)
        return get!(storage.derived_function_maps, key) do
            # PERFORMANCE NOTE: Only construct key inside this do-block to
            # ensure expensive constructor only called once, the first time.

            # TODO: Use the macro's returntype to strongly type the value.
            #       We'll have to generate this function from within the macro, like we used to
            #       in the existing open-source Salsa.
            # NOTE: Except actually after https://github.com/RelationalAI-oss/Salsa.jl/issues/11
            #       maybe we won't do this anymore, and we'll just use one big dictionary!
            Dict{TT,DerivedValue}()
        end
    finally
        unlock(storage.lock)
    end
end
function get_map_for_key(storage::DefaultStorage, ::InputKey)
    # We use one big dictionary for the inputs, storing them all together, so any input key
    # would return the same value here. :)
    return storage.inputs_map
end


function Salsa._previous_output_internal(
    runtime::Salsa._TracingRuntimeWithStorage{DefaultStorage},
    key::DependencyKey{<:DerivedKey},
)
    storage = _storage(runtime)
    derived_key, args = key.key, key.args

    previous_output = nothing

    try
        lock(storage.lock)
        cache = get_map_for_key(storage, derived_key)

        if haskey(cache, args)
            previous_output = getindex(cache, args)
        end
    finally
        unlock(storage.lock)
    end

    return previous_output
end


# TODO: I think we can @nospecialize the arguments for compiler performance?
# TODO: It doesn't seem like this @nospecialize is working... It still seems to be compiling
# a nospecialization for every argument type. :(
function Salsa._memoized_lookup_internal(
    runtime::Salsa._TracingRuntimeWithStorage{DefaultStorage},
    key::DependencyKey{<:DerivedKey},
)
    storage = _storage(runtime)
    try  # For storage.derived_functions_active
        try
            lock(storage.lock)
            storage.derived_functions_active += 1
        finally
            unlock(storage.lock)
        end

        existing_value = nothing
        value = nothing

        derived_key, args = key.key, key.args

        # NOTE: We currently make no attempts to prevent two Tasks from simultaneously
        # computing the same derived function for the same key. For cheap derived functions
        # this may be a more optimal behavior than the overhead caused by coordination.
        # However for expensive functions, this is not ideal. We take this approach for now
        # because it is simpler.

        # The locking here is a bit involved, to prevent the lock from being held during
        # user computation.
        # We minimally lock only around the accesses to the fields of storage.
        # NOTE: It is okay to release and then reacquire the lock inside this function
        # while computing the result because we are guaranteed that inputs cannot be
        # modified while this function is running, so we do not need to fear concurrency
        # violations, e.g. overwriting newer values with outdated results.
        lock_held::Bool = false
        local cache
        try
            lock(storage.lock)
            lock_held = true

            cache = get_map_for_key(storage, derived_key)

            if haskey(cache, args)
                # TODO: Optimization idea:
                #   - There's no reason to be tracing the Salsa functions during
                #     the `still_valid` check, since we're not going to use them. We might
                #     _do_ still want to keep the stack trace though for cycle detection and
                #     error messages.
                #   - We might want to consider keeping some toggle on the Trace object
                #     itself, to allow us to skip recording the deps for this phase.

                existing_value = getindex(cache, args)
                unlock(storage.lock)
                lock_held = false

                # NOTE: There is no race condition possible here, despite that the storage
                # isn't locked, because all code that might bump `current_revision`
                # (`set_input!` and `delete_input!`) first asserts that there are no active
                # derived functions (`derived_functions_active == 0`). Meaning that this
                # value will be stable across the lifetime of this function.
                if existing_value.verified_at == storage.current_revision
                    value = existing_value
                    # NOTE: still_valid() will recursively call memoized_lookup, potentially
                    #       recomputing all our recursive dependencies.
                elseif still_valid(runtime, existing_value)
                    # Update the verified_at field, but otherwise use the existing value.
                    # NOTE: As above, current_revision is safe to read during this function
                    # without a lock, due to asserts on derived_functions_active.
                    existing_value.verified_at = storage.current_revision
                    value = existing_value
                end
            end
        finally
            if lock_held
                unlock(storage.lock)
                lock_held = false
            end
        end

        # At this point (value == nothing) if (and only if) the args are not
        # in the cache, OR if they are in the cache, but they are no longer valid.
        if value === nothing    # N.B., do not use `isnothing`
            # TODO: Optimization idea:
            #   - If `existing_value !== nothing` here, we can avoid an allocation and a
            #     copy by _swapping_ the `trace`'s `ordered_dependencies` with
            #     `value.dependencies`, so that the deps are written in-place directly into
            #     their final destination! :)

            @dbg_log_trace @info "invoking $key"
            v = invoke_user_function(runtime, key.key, key.args...)
            # NOTE: We use `isequal` for the Early Exit Optimization, since values are
            # required to be purely immutable (but not necessarily julia `immutable
            # structs`).
            @dbg_log_trace @info "Returning from $key."
            if existing_value !== nothing && isequal(existing_value.value, v)
                # Early Exit Optimization Part 2: (for Part 1 see `set_input!`, below).
                # If a derived function computes the exact same value, we can terminate
                # early and "backdate" the changed_at field to say this value has _not_
                # changed.
                # NOTE: As above, current_revision is safe to read during this function
                #       without a lock, due to asserts on derived_functions_active.
                existing_value.verified_at = storage.current_revision
                # Note that just because it computed the same value, it doesn't mean it
                # computed it in the same way, so we need to update the list of
                # dependencies as well.
                existing_value.dependencies = collect_trace(runtime)
                # We keep the old computed `.value` rather than the new value to help catch
                # bugs with users' over-permissive `isequal()` functions earlier.
                value = existing_value
            else
                @dbg_log_trace @info "Computed new derived value for $key."
                # The user function computed a new value, which we must now store.
                value = DerivedValue(
                    v,
                    collect_trace(runtime),
                    storage.current_revision,
                    storage.current_revision,
                )
                try
                    lock(storage.lock)
                    cache[args] = value
                finally
                    unlock(storage.lock)
                end
            end # existing_value
        end # if value === nothing

        return value
    finally
        try
            lock(storage.lock)
            storage.derived_functions_active -= 1
        finally
            unlock(storage.lock)
        end
    end
end # _memoized_lookup_internal

function Salsa._unwrap_salsa_value(
    runtime::RuntimeWithStorage{DefaultStorage},
    v::Union{DerivedValue{T},InputValue{T}},
)::T where {T}
    return v.value
end

# A `value` is still valid if none of its dependencies have changed.
function still_valid(runtime, value)
    for depkey in value.dependencies
        dep_changed_at = key_changed_at(runtime, depkey)
        if dep_changed_at > value.verified_at
            return false
        end
    end # for
    return true
end

function key_changed_at(runtime, key::DependencyKey)
    return _changed_at(memoized_lookup(runtime, key))
end

# =============================================================================

# --- Inputs --------------------------------------------------------------------------

# TODO: I think we can @nospecialize the arguments for compiler performance?
function Salsa._memoized_lookup_internal(
    runtime::Salsa._TracingRuntimeWithStorage{DefaultStorage},
    # TODO: It doesn't look like this nospecialize is actually doing anything...
    key::DependencyKey{<:InputKey{F}},
) where {F}
    typedkey, call_args = key.key, key.args
    cache_key = (F, call_args)
    storage = _storage(runtime)
    cache = get_map_for_key(storage, typedkey)
    try
        lock(storage.lock)
        return cache[cache_key]
    finally
        unlock(storage.lock)
    end
end

function Salsa.set_input!(
    runtime::_TopLevelRuntimeWithStorage{DefaultStorage},
    key::DependencyKey{<:InputKey{F}},
    value::T,
) where {F,T}
    storage = _storage(runtime)
    typedkey, call_args = key.key, key.args
    cache_key = (F, call_args)

    # NOTE: PERFORMANCE HAZARD: For some MYSTERY REASON, using the `lock(l) do ... end`
    # syntax causes an allocation here and doubles the runtime, but this manual try-finally
    # does not, so it is preferable and we should stick with this.
    try
        lock(storage.lock)
        cache = get_map_for_key(storage, typedkey)

        if haskey(cache, cache_key) && _value_isequal_to_cached(cache[cache_key], value)
            # Early Exit Optimization Part 1: Don't dirty anything if setting exactly the
            # same value for an input.
            return
        end

        # It is an error to modify any inputs while derived functions are active, even
        # concurrently on other threads.
        @assert storage.derived_functions_active == 0

        @dbg_log_trace @info "Setting input $key => $value"
        storage.current_revision += 1

        cache[cache_key] = InputValue(value, storage.current_revision)
        return nothing
    finally
        unlock(storage.lock)
    end
end
# This function barrier exists to allow specializing the `.value` on the type of
# the cached InputValue. (It doesn't seem to have any effect on performance though?)
function _value_isequal_to_cached(cached::InputValue, value)
    # NOTE: We use `isequal` for the Early Exit Optimization, since we compare values _by
    # value_, not by identity. (That is, `[] == []`, despite `[] !== []`.) And we prefer
    # isequal over `==` since we want to preserve float diffs, just like a Dict would.
    return isequal(cached.value, value)
end

function Salsa.delete_input!(
    runtime::_TopLevelRuntimeWithStorage{DefaultStorage},
    key::DependencyKey{<:InputKey{F}},
) where {F}
    @dbg_log_trace @info "Deleting input $key"
    storage = _storage(runtime)
    typedkey, call_args = key.key, key.args
    cache_key = (F, call_args)

    # NOTE: PERFORMANCE HAZARD: For some MYSTERY REASON, using the `lock(l) do ... end`
    # syntax causes an allocation here and doubles the runtime, but this manual try-finally
    # does not, so it is preferable and we should stick with this.
    try
        lock(storage.lock)
        # It is an error to modify any inputs while derived functions are active, even
        # concurrently on other threads.
        @assert storage.derived_functions_active == 0

        storage.current_revision += 1
        cache = get_map_for_key(storage, typedkey)
        delete!(cache, cache_key)
        return nothing
    finally
        unlock(storage.lock)
    end
end

function Salsa.new_epoch!(runtime::Salsa.RuntimeWithStorage{DefaultStorage})
end

end  # module
