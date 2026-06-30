--- Fine-grained reactive core for heirline.
---
--- This module implements a small, dependency-tracking reactive system in the
--- style of SolidJS / the "reactively" algorithm. It is the substrate the rest
--- of heirline is built on: state is expressed as `signal`s, derived values as
--- `memo`s, and side effects (such as requesting a statusline redraw) as
--- `effect`s. Reads performed while a memo or effect is executing are recorded
--- automatically, so a change to a signal only recomputes the memos and effects
--- that actually depend on it.
---
--- The public surface is deliberately closure-based: `signal`/`memo`/`effect`
--- hand back plain functions that close over their node, rather than exposing
--- objects with methods. Internally each reactive value is a small, flat record
--- (a "node") because the dependency graph needs stable identities to link
--- sources and observers together.
---
--- Update algorithm (mark-and-sweep, glitch-free and lazy):
---   * Writing a signal marks its direct observers DIRTY and their transitive
---     observers CHECK, then flushes queued effects.
---   * Reading a memo brings it up to date on demand: a CHECK node first asks
---     its sources to update; it only recomputes if one of them actually
---     changed (became DIRTY). This avoids recomputing memos nobody reads and
---     guarantees each memo runs at most once per change.
---@class heirline.Reactive
local M = {}

-- Node freshness states, ordered by severity so `stale()` can compare them.
local CLEAN = 0 -- value is up to date
local CHECK = 1 -- a transitive source may have changed; verify before reuse
local DIRTY = 2 -- a direct source changed; recompute on next read

--- The reactive node currently executing. Signal and memo reads performed while
--- this is set are recorded as dependencies of this node.
---@type heirline.reactive.Node?
local listener = nil

--- New sources read by `listener` after its dependency list diverged from the
--- previous run. While reads still match the previous run in order we simply
--- advance `cur_source_count` instead of allocating; once a read diverges we
--- start collecting the remaining sources here so the lists can be reconciled.
---@type heirline.reactive.Node[]?
local cur_sources = nil

--- Count of leading sources that matched the previous run in order.
local cur_source_count = 0

--- The ownership scope nodes are registered under as they are created, so a
--- parent computation (or a `root`) can dispose the whole subtree at once.
---@type heirline.reactive.Owner?
local current_owner = nil

--- Effects whose recomputation has been deferred until the current batch (or
--- the current write) settles. Membership is deduplicated by the CLEAN->stale
--- transition in `stale()`.
---@type heirline.reactive.Node[]
local pending_effects = {}

--- Depth of nested `batch` calls; while greater than zero, writes defer their
--- effect flush to the outermost batch boundary.
local batch_depth = 0

--- Guards against re-entrant flushing: a write performed from inside an effect
--- appends to `pending_effects` and is drained by the in-progress flush loop
--- rather than starting a nested one.
local flushing = false

---@class heirline.reactive.Node
---@field fn? fun(): any The computation for memos/effects; nil for plain signals.
---@field value any The cached value.
---@field state integer One of CLEAN/CHECK/DIRTY.
---@field effect? boolean True for effect nodes (eagerly flushed sinks).
---@field equals? fun(a: any, b: any): boolean|false Equality test, or false to always notify.
---@field sources? heirline.reactive.Node[] Nodes this node read last run.
---@field observers? heirline.reactive.Node[] Nodes that read this node.
---@field owned? heirline.reactive.Node[] Child nodes created during this node's run.
---@field cleanups? (fun(): any)[] Callbacks to run before recompute/disposal.
---@field disposed? boolean True once the node has been torn down.

---@class heirline.reactive.Owner
---@field owned? heirline.reactive.Node[]

--- Compare two values under a node's equality policy.
--- A node may set `equals` to a custom predicate, or to `false` to declare that
--- every write is a change (useful for signals holding mutable tables).
---@param node heirline.reactive.Node
---@param a any
---@param b any
---@return boolean
local function node_equals(node, a, b)
    local eq = node.equals
    if eq == nil then
        return a == b
    elseif eq == false then
        return false
    else
        return eq(a, b)
    end
end

--- Register a freshly created node with the active ownership scope, if any, so
--- it is disposed when its owner re-runs or is disposed.
---@param node heirline.reactive.Node
local function register_owned(node)
    local owner = current_owner
    if owner then
        if owner.owned then
            owner.owned[#owner.owned + 1] = node
        else
            owner.owned = { node }
        end
    end
end

--- Record that `listener` (the running node) read `node`, reusing the previous
--- dependency list in order for as long as the reads match it.
---@param node heirline.reactive.Node
local function track(node)
    if not listener then
        return
    end
    local prev = listener.sources
    if cur_sources == nil and prev and prev[cur_source_count + 1] == node then
        cur_source_count = cur_source_count + 1
    elseif cur_sources == nil then
        cur_sources = { node }
    else
        cur_sources[#cur_sources + 1] = node
    end
end

--- Unsubscribe `node` from the observer lists of its sources beyond `from`
--- (a count of leading sources to keep). Uses swap-with-last removal.
---@param node heirline.reactive.Node
---@param from integer
local function remove_source_observers(node, from)
    local sources = node.sources
    if not sources then
        return
    end
    for i = from + 1, #sources do
        local observers = sources[i].observers
        if observers then
            for j = 1, #observers do
                if observers[j] == node then
                    observers[j] = observers[#observers]
                    observers[#observers] = nil
                    break
                end
            end
        end
    end
end

--- Run a node's cleanups and dispose any child nodes it created, leaving it
--- ready to recompute. Called before recomputation and during disposal.
---@param node heirline.reactive.Node
local function clean_node(node)
    local dispose_node = M._dispose_node
    if node.owned then
        local owned = node.owned
        for i = #owned, 1, -1 do
            dispose_node(owned[i])
        end
        node.owned = nil
    end
    if node.cleanups then
        local cleanups = node.cleanups
        for i = #cleanups, 1, -1 do
            cleanups[i]()
        end
        node.cleanups = nil
    end
end

--- Reconcile the running node's dependency edges after its computation ran,
--- using the `cur_sources`/`cur_source_count` captured during the run.
---@param node heirline.reactive.Node
local function reconcile_sources(node)
    local sources = node.sources
    if cur_sources then
        -- Drop edges to sources past the matched prefix, then graft the newly
        -- read tail onto the kept prefix.
        remove_source_observers(node, cur_source_count)
        if sources and cur_source_count > 0 then
            for i = #sources, cur_source_count + 1, -1 do
                sources[i] = nil
            end
            for i = 1, #cur_sources do
                sources[cur_source_count + i] = cur_sources[i]
            end
        else
            node.sources = cur_sources
            sources = cur_sources
        end
        for i = cur_source_count + 1, #sources do
            local src = sources[i]
            if src.observers then
                src.observers[#src.observers + 1] = node
            else
                src.observers = { node }
            end
        end
    elseif sources and cur_source_count < #sources then
        -- Fewer reads than last time, all matching the prefix: trim the rest.
        remove_source_observers(node, cur_source_count)
        for i = #sources, cur_source_count + 1, -1 do
            sources[i] = nil
        end
    end
end

--- Recompute a node, capturing the signals/memos it reads as its new
--- dependencies and propagating a DIRTY mark to observers if its value changed.
---@param node heirline.reactive.Node
local function update(node)
    if not node.fn then
        return
    end
    clean_node(node)

    local prev_value = node.value
    local prev_listener = listener
    local prev_sources = cur_sources
    local prev_count = cur_source_count
    local prev_owner = current_owner

    listener = node
    cur_sources = nil
    cur_source_count = 0
    current_owner = node

    local ok, result = pcall(node.fn)
    if ok then
        reconcile_sources(node)
    end

    listener = prev_listener
    cur_sources = prev_sources
    cur_source_count = prev_count
    current_owner = prev_owner

    if not ok then
        -- Leave the node clean so reads do not spin on a failing computation,
        -- and surface the error to the caller that triggered the recompute.
        node.state = CLEAN
        error(result, 0)
    end

    node.value = result
    if node.observers and not node_equals(node, prev_value, result) then
        local observers = node.observers
        for i = 1, #observers do
            observers[i].state = DIRTY
        end
    end
    node.state = CLEAN
end

--- Bring a node up to date if its freshness is in doubt. A CHECK node verifies
--- its sources first and only recomputes when one of them actually changed.
---@param node heirline.reactive.Node
local function update_if_necessary(node)
    if node.state == CHECK then
        local sources = node.sources
        if sources then
            for i = 1, #sources do
                update_if_necessary(sources[i])
                if node.state == DIRTY then
                    break
                end
            end
        end
    end
    if node.state == DIRTY then
        update(node)
    end
    node.state = CLEAN
end

--- Propagate a freshness mark up the observer graph. Direct observers of a
--- changed signal are marked DIRTY; everything reachable beyond them is marked
--- CHECK. Effects newly knocked out of CLEAN are queued for flushing.
---@param node heirline.reactive.Node
---@param state integer
local function stale(node, state)
    if node.state < state then
        if node.state == CLEAN and node.effect then
            pending_effects[#pending_effects + 1] = node
        end
        node.state = state
        local observers = node.observers
        if observers then
            for i = 1, #observers do
                stale(observers[i], CHECK)
            end
        end
    end
end

--- Drain the pending-effect queue, recomputing each effect that is still stale.
--- Re-entrant calls are no-ops; effects queued while flushing are picked up by
--- the running loop.
local function flush()
    if flushing then
        return
    end
    flushing = true
    local i = 1
    while i <= #pending_effects do
        local node = pending_effects[i]
        if node.state ~= CLEAN and not node.disposed then
            update_if_necessary(node)
        end
        i = i + 1
    end
    for j = #pending_effects, 1, -1 do
        pending_effects[j] = nil
    end
    flushing = false
end

--- Tear down a node: run its cleanups, dispose owned children, and detach it
--- from the dependency graph so it is never recomputed again.
---@param node heirline.reactive.Node
local function dispose_node(node)
    if node.disposed then
        return
    end
    clean_node(node)
    remove_source_observers(node, 0)
    if node.sources then
        for i = #node.sources, 1, -1 do
            node.sources[i] = nil
        end
    end
    node.observers = nil
    node.state = CLEAN
    node.fn = nil
    node.disposed = true
end
-- Exposed on the module so `clean_node`, defined earlier, can reach it without
-- a forward-declaration dance; not part of the public API.
M._dispose_node = dispose_node

--- Read a node's value, recording the dependency and bringing memos up to date.
---@param node heirline.reactive.Node
---@return any
local function read(node)
    track(node)
    if node.fn then
        update_if_necessary(node)
    end
    return node.value
end

--- Create a reactive signal: a readable/writable piece of state.
---
--- Returns a getter and a setter. Calling the getter inside a memo or effect
--- subscribes that computation to the signal. Calling the setter notifies
--- subscribers when the value changes (per the equality policy) and, unless a
--- `batch` is open, immediately flushes affected effects.
---@generic T
---@param value T initial value
---@param opts? { equals?: (fun(a: T, b: T): boolean)|false } equality policy; `false` notifies on every write
---@return fun(): T get, fun(v: T): T set
function M.signal(value, opts)
    local node = { value = value, state = CLEAN }
    if opts and opts.equals ~= nil then
        node.equals = opts.equals
    end

    local function get()
        return read(node)
    end

    local function set(new_value)
        if not node_equals(node, node.value, new_value) then
            node.value = new_value
            local observers = node.observers
            if observers then
                for i = 1, #observers do
                    stale(observers[i], DIRTY)
                end
            end
            if batch_depth == 0 then
                flush()
            end
        end
        return node.value
    end

    return get, set
end

--- Create a memo: a lazily-evaluated, cached derived value.
---
--- The function re-runs only when one of the signals or memos it reads changes,
--- and only when the memo is actually read. Returns a getter; reading it inside
--- another computation subscribes that computation to the memo.
---@generic T
---@param fn fun(): T computation deriving the value from other reactive reads
---@param opts? { equals?: (fun(a: T, b: T): boolean)|false } equality policy for change propagation
---@return fun(): T get
function M.memo(fn, opts)
    local node = { fn = fn, value = nil, state = DIRTY }
    if opts and opts.equals ~= nil then
        node.equals = opts.equals
    end
    register_owned(node)
    return function()
        return read(node)
    end
end

--- Create an effect: a computation run for its side effects.
---
--- The effect runs once immediately, then re-runs whenever a signal or memo it
--- read changes. Register teardown logic with `on_cleanup`; it runs before each
--- re-run and on disposal. Returns a dispose function that tears the effect
--- down. If created inside another computation or a `root`, it is also disposed
--- automatically when that owner is.
---@param fn fun(): any
---@return fun() dispose
function M.effect(fn)
    local node = { fn = fn, value = nil, state = DIRTY, effect = true }
    register_owned(node)
    pending_effects[#pending_effects + 1] = node
    if batch_depth == 0 then
        flush()
    end
    return function()
        dispose_node(node)
    end
end

--- Run `fn` without subscribing the surrounding computation to anything read
--- inside it. Useful for reading reactive state from within an effect without
--- creating a dependency on it.
---@generic T
---@param fn fun(): T
---@return T
function M.untrack(fn)
    local prev = listener
    listener = nil
    local ok, result = pcall(fn)
    listener = prev
    if not ok then
        error(result, 0)
    end
    return result
end

--- Group multiple writes so that dependent effects run once, after the whole
--- batch settles, instead of after each individual write. Nested batches defer
--- to the outermost one. Returns whatever `fn` returns.
---@generic T
---@param fn fun(): T
---@return T
function M.batch(fn)
    if batch_depth > 0 then
        return fn()
    end
    batch_depth = batch_depth + 1
    local ok, result = pcall(fn)
    batch_depth = batch_depth - 1
    flush()
    if not ok then
        error(result, 0)
    end
    return result
end

--- Register a cleanup callback on the currently executing computation. It runs
--- immediately before the computation's next recomputation and once more when
--- the computation is disposed. Outside any computation this is a no-op.
---@param fn fun(): any
---@return fun(): any fn
function M.on_cleanup(fn)
    if listener then
        if listener.cleanups then
            listener.cleanups[#listener.cleanups + 1] = fn
        else
            listener.cleanups = { fn }
        end
    end
    return fn
end

--- Create a disposal scope that is never tracked by an outer computation. The
--- callback receives a `dispose` function that tears down every effect and memo
--- created within the scope. Returns whatever `fn` returns. Use this to own a
--- tree of long-lived effects (for example, the reactive state for a window).
---@generic T
---@param fn fun(dispose: fun()): T
---@return T
function M.root(fn)
    local owner = {}
    local prev_owner = current_owner
    local prev_listener = listener
    current_owner = owner
    listener = nil

    local function dispose()
        if owner.owned then
            local owned = owner.owned
            for i = #owned, 1, -1 do
                dispose_node(owned[i])
            end
            owner.owned = nil
        end
    end

    local ok, result = pcall(fn, dispose)
    current_owner = prev_owner
    listener = prev_listener
    if not ok then
        error(result, 0)
    end
    return result
end

--- Flush any pending effects synchronously. Writes outside a `batch` flush on
--- their own, so this is only needed by integration code that mutates signals
--- through lower-level means and wants effects to settle immediately.
function M.flush()
    flush()
end

return M
