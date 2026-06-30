--- Signal-first component constructors.
---
--- A component is a closure `fun(ctx: heirline.Context): fun(): string`. Calling
--- it instantiates the component in the current reactive scope and returns a
--- getter for its rendered fragment. Each fragment is backed by a `memo`, so a
--- component only re-renders when a signal it actually read changes, and a
--- parent only reconcatenates when one of its children's fragments changes.
---
--- Highlights inherit down the tree: a component merges its own highlight over
--- the inherited one and passes the result to its children, exactly mirroring
--- heirline's classic merge semantics, but resolved reactively.
---@class heirline.Component
local M = {}

local r = require("heirline.reactive")
local hi = require("heirline.highlights")
local utils = require("heirline.utils")

---@class heirline.Context
---@field win integer The window the line is being rendered for.
---@field buf integer The buffer displayed in `win`.
---@field tab? integer The tabpage, when relevant (tabline rendering).
---@field hl fun(): table A getter for the inherited, already-merged highlight.
---@field lnum? fun(): integer Statuscolumn only: reactive `v:lnum` for the line being drawn.
---@field relnum? fun(): integer Statuscolumn only: reactive `v:relnum` for the line being drawn.
---@field virtnum? fun(): integer Statuscolumn only: reactive `v:virtnum` for the line being drawn.
---@field flex? heirline.flexible.Registry The scope's flexible-component registry, when width adaptation is enabled.

---@alias heirline.Provider string|number|fun(ctx: heirline.Context): (string|number|nil)
---@alias heirline.HlSpec HeirlineHighlight|string|fun(ctx: heirline.Context): (HeirlineHighlight|string|nil)
---@alias heirline.Condition fun(ctx: heirline.Context): any

---@alias heirline.OnClickCallback fun(ctx: heirline.Context, minwid: integer, nclicks: integer, button: string, mods: string): any
---@class heirline.OnClick
---@field callback heirline.OnClickCallback|string The Lua handler, or a Vim function/expression name to call directly.
---@field name? string|fun(ctx: heirline.Context): string A stable global name for the handler; auto-generated when omitted.
---@field minwid? integer|fun(ctx: heirline.Context): integer The `minwid` passed to the handler.
---@field update? boolean Re-register the handler even if a function of `name` already exists.

---@class heirline.ComponentOpts
---@field hl? heirline.HlSpec Highlight for this component, merged over the inherited one.
---@field condition? heirline.Condition When it returns falsy, the component renders nothing.
---@field on_click? heirline.OnClick|heirline.OnClickCallback Make the component clickable.

--- Resolve a highlight spec to a plain highlight table in the given context.
--- Functions are called with the context; string names are looked up.
---@param spec? heirline.HlSpec
---@param ctx heirline.Context
---@return table
local function resolve_own_hl(spec, ctx)
    local hl = spec
    if type(hl) == "function" then
        hl = hl(ctx)
    end
    if type(hl) == "string" then
        hl = utils.get_highlight(hl)
    end
    return hl or {}
end

--- Merge an inherited highlight with a component's own, honouring the `force`
--- flag: by default the child wins, but a forcing parent overrides the child.
---@param parent table
---@param own table
---@return table
local function merge_hl(parent, own)
    if not parent or next(parent) == nil then
        return own
    end
    if not own or next(own) == nil then
        return parent
    end
    if parent.force then
        return vim.tbl_extend("keep", parent, own)
    end
    return vim.tbl_extend("force", parent, own)
end

--- Build a memo yielding this component's merged highlight, reactive in both the
--- inherited highlight and any signals read by an `hl` function.
---@param spec? heirline.HlSpec
---@param ctx heirline.Context
---@return fun(): table
local function merged_hl_getter(spec, ctx)
    return r.memo(function()
        return merge_hl(ctx.hl(), resolve_own_hl(spec, ctx))
    end)
end

--- Monotonic counter backing auto-generated `on_click` handler names.
local click_counter = 0

--- Resolve a `minwid` spec to the value embedded in the click region.
---@param minwid? integer|fun(ctx: heirline.Context): integer
---@param ctx heirline.Context
---@return integer|string
local function resolve_minwid(minwid, ctx)
    if minwid == nil then
        return ""
    end
    if type(minwid) == "function" then
        return minwid(ctx)
    end
    return minwid
end

--- Set up a component's click handler and return the markup that wraps its
--- fragment into a clickable region (`prefix`, `suffix`). Registers a global
--- handler for Lua callbacks (cleaned up with the owning scope) or points the
--- region directly at a named Vim function for string callbacks.
---@param spec? heirline.OnClick|heirline.OnClickCallback
---@param ctx heirline.Context
---@return string prefix, string suffix
local function setup_on_click(spec, ctx)
    if not spec then
        return "", ""
    end

    local callback, name, minwid, update
    if type(spec) == "function" then
        callback = spec
    else
        callback, name, minwid, update = spec.callback, spec.name, spec.minwid, spec.update
    end

    local mw = resolve_minwid(minwid, ctx)

    -- A string callback names a Vim function/expression; reference it directly.
    if type(callback) == "string" then
        return ("%%%s@%s@"):format(mw, callback), "%X"
    end

    local fname = type(name) == "function" and name(ctx) or name
    if not fname then
        click_counter = click_counter + 1
        fname = "HeirlineOnClick" .. click_counter
    end

    if update or _G[fname] == nil then
        _G[fname] = function(handler_minwid, nclicks, button, mods)
            return callback(ctx, handler_minwid, nclicks, button, mods)
        end
        r.on_cleanup(function()
            _G[fname] = nil
        end)
    end

    return ("%%%s@v:lua.%s@"):format(mw, fname), "%X"
end

--- Derive a child context that inherits every field of its parent but carries a
--- new inherited-highlight getter for descendants.
---@param ctx heirline.Context
---@param hl fun(): table
---@return heirline.Context
local function derive_ctx(ctx, hl)
    local child = {}
    for k, v in pairs(ctx) do
        child[k] = v
    end
    child.hl = hl
    return child
end

--- Create a leaf component that renders text from a provider.
---
--- The provider is a string/number or a function of the context. The produced
--- fragment is wrapped in the component's merged highlight. When the provider
--- yields an empty string the fragment is empty and contributes no highlight.
---@param provider heirline.Provider
---@param opts? heirline.ComponentOpts
---@return fun(ctx: heirline.Context): fun(): string
function M.text(provider, opts)
    opts = opts or {}
    local condition = opts.condition
    return function(ctx)
        local hl = merged_hl_getter(opts.hl, ctx)
        local click_prefix, click_suffix = setup_on_click(opts.on_click, ctx)
        return r.memo(function()
            if condition and not condition(ctx) then
                return ""
            end
            local value = provider
            if type(value) == "function" then
                value = value(ctx)
            end
            if value == nil then
                return ""
            end
            local str = tostring(value)
            if str == "" then
                return ""
            end
            local start, finish = hi.eval_hl(hl())
            return click_prefix .. start .. str .. finish .. click_suffix
        end)
    end
end

--- Create a composite component that concatenates its children.
---
--- The group's own highlight is merged over the inherited one and handed down
--- to the children as their inherited highlight. The group re-concatenates only
--- when one of its children's fragments changes.
---@param children (fun(ctx: heirline.Context): fun(): string)[]
---@param opts? heirline.ComponentOpts
---@return fun(ctx: heirline.Context): fun(): string
function M.group(children, opts)
    opts = opts or {}
    local condition = opts.condition
    return function(ctx)
        local hl = merged_hl_getter(opts.hl, ctx)
        local child_ctx = derive_ctx(ctx, hl)
        local click_prefix, click_suffix = setup_on_click(opts.on_click, ctx)
        local fragments = {}
        for i = 1, #children do
            fragments[i] = children[i](child_ctx)
        end
        return r.memo(function()
            if condition and not condition(ctx) then
                return ""
            end
            local parts = {}
            for i = 1, #fragments do
                parts[i] = fragments[i]()
            end
            local body = table.concat(parts)
            if body == "" then
                return ""
            end
            return click_prefix .. body .. click_suffix
        end)
    end
end

--- Create a flexible component that renders one of several options to fit the
--- available width.
---
--- The options are other components, ordered widest (most detailed) first. The
--- component renders the widest option that fits; the render driver narrows it
--- as space runs out. `priority` orders contraction across flexible components
--- (lower contracts first) and is required for top-level flexible components;
--- nested ones may pass `nil` to derive their priority from the enclosing
--- flexible component.
---@param priority integer? Contraction priority; required at the top level, derivable when nested.
---@param options (fun(ctx: heirline.Context): fun(): string)[] Option components, widest first.
---@param opts? heirline.ComponentOpts
---@return fun(ctx: heirline.Context): fun(): string
function M.flexible(priority, options, opts)
    opts = opts or {}
    local condition = opts.condition
    return function(ctx)
        local hl = merged_hl_getter(opts.hl, ctx)
        local child_ctx = derive_ctx(ctx, hl)
        local index, set_index = r.signal(1)

        ---@type heirline.flexible.Entry
        local entry = { priority = priority, index = index, set_index = set_index }
        local registry = ctx.flex
        if registry then
            -- Register before instantiating options so nested flexible
            -- components link to this one as their parent.
            registry.register(entry)
            registry.push(entry)
        end

        local fragments = {}
        for i = 1, #options do
            fragments[i] = options[i](child_ctx)
        end

        if registry then
            registry.pop()
        end
        entry.options = fragments
        entry.count = #fragments

        return r.memo(function()
            if condition and not condition(ctx) then
                return ""
            end
            if entry.count == 0 then
                return ""
            end
            return fragments[index()]()
        end)
    end
end

---@class heirline.list.Child
---@field get fun(): string The child's rendered fragment getter.
---@field dispose fun() Tears down the child's reactive scope.

--- Instantiate one list child in its own disposable reactive scope.
---@param factory fun(item: any, index: integer): (fun(ctx: heirline.Context): fun(): string)
---@param ctx heirline.Context
---@param item any
---@param index integer
---@return heirline.list.Child
local function create_list_child(factory, ctx, item, index)
    local child
    r.root(function(dispose)
        child = { get = factory(item, index)(ctx), dispose = dispose }
    end)
    return child
end

---@class heirline.list.Entry
---@field key any The item's stable identity.
---@field get fun(): string The rendered fragment getter for the item.

---@class heirline.ListOpts
---@field items fun(ctx: heirline.Context): any[] Reactive list of items to render.
---@field render fun(item: any, index: integer): (fun(ctx: heirline.Context): fun(): string) Builds a component for an item.
---@field key? fun(item: any, index: integer): any Stable identity for an item (defaults to the item itself).
---@field layout? fun(entries: heirline.list.Entry[], ctx: heirline.Context): string Compose the ordered entries into the final string; defaults to concatenating them all.
---@field hl? heirline.HlSpec
---@field condition? heirline.Condition

--- Create a dynamic, keyed list component.
---
--- `items` is read reactively; each item is rendered by the component returned
--- from `render`, in its own scope so it can hold per-item reactive state. As
--- the item list changes, children for new keys are created and children whose
--- keys disappear are disposed. Every child is torn down when the list's own
--- scope is. Children persist across updates while their key remains, so a
--- component keyed by (say) a buffer number keeps its state as the list reorders.
---
--- By default the children are concatenated in order; pass `layout` to compose
--- them differently — for example to render only a subset (paging) with markers
--- around it.
---@param spec heirline.ListOpts
---@return fun(ctx: heirline.Context): fun(): string
function M.list(spec)
    local key_of = spec.key
    local layout = spec.layout
    return function(ctx)
        local hl = merged_hl_getter(spec.hl, ctx)
        local base_ctx = derive_ctx(ctx, hl)

        --- Live children keyed by item identity.
        ---@type table<any, heirline.list.Child>
        local children = {}

        -- Tear every child down when the enclosing scope is disposed.
        r.on_cleanup(function()
            for k, child in pairs(children) do
                child.dispose()
                children[k] = nil
            end
        end)

        return r.memo(function()
            if spec.condition and not spec.condition(base_ctx) then
                return ""
            end

            local items = spec.items(base_ctx) or {}
            local present = {}
            local ordered = {}
            for index = 1, #items do
                local item = items[index]
                local key = key_of and key_of(item, index) or item
                present[key] = true
                local child = children[key]
                if not child then
                    child = create_list_child(spec.render, base_ctx, item, index)
                    children[key] = child
                end
                ordered[index] = { key = key, get = child.get }
            end

            -- Dispose children whose keys are no longer present.
            for key, child in pairs(children) do
                if not present[key] then
                    child.dispose()
                    children[key] = nil
                end
            end

            if layout then
                return layout(ordered, base_ctx)
            end

            local parts = {}
            for index = 1, #ordered do
                parts[index] = ordered[index].get()
            end
            return table.concat(parts)
        end)
    end
end

--- Wrap a component in separator delimiters tinted by a shared colour.
---
--- The left and right delimiters are drawn in `color` as their foreground while
--- the wrapped component is drawn over `color` as its background, producing the
--- familiar "powerline" surround. `color` may be a colour or a function of the
--- context (returning nil to draw no tint); `delimiters` is a `{ left, right }`
--- pair.
---@param delimiters string[]
---@param color heirline.HlSpec|nil|fun(ctx: heirline.Context): (HeirlineColor|nil)
---@param child fun(ctx: heirline.Context): fun(): string
---@return fun(ctx: heirline.Context): fun(): string
function M.surround(delimiters, color, child)
    local function tint(ctx)
        if type(color) == "function" then
            return color(ctx)
        end
        return color
    end

    return M.group({
        M.text(delimiters[1], {
            hl = function(ctx)
                local c = tint(ctx)
                return c and { fg = c } or nil
            end,
        }),
        M.group({ child }, {
            hl = function(ctx)
                local c = tint(ctx)
                return c and { bg = c } or nil
            end,
        }),
        M.text(delimiters[2], {
            hl = function(ctx)
                local c = tint(ctx)
                return c and { fg = c } or nil
            end,
        }),
    })
end

return M

