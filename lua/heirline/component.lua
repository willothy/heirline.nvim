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

---@alias heirline.Provider string|number|fun(ctx: heirline.Context): (string|number|nil)
---@alias heirline.HlSpec HeirlineHighlight|string|fun(ctx: heirline.Context): (HeirlineHighlight|string|nil)
---@alias heirline.Condition fun(ctx: heirline.Context): any

---@class heirline.ComponentOpts
---@field hl? heirline.HlSpec Highlight for this component, merged over the inherited one.
---@field condition? heirline.Condition When it returns falsy, the component renders nothing.

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

--- Derive a child context that inherits `win`/`buf`/`tab` but carries a new
--- inherited-highlight getter for descendants.
---@param ctx heirline.Context
---@param hl fun(): table
---@return heirline.Context
local function derive_ctx(ctx, hl)
    return { win = ctx.win, buf = ctx.buf, tab = ctx.tab, hl = hl }
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
            return start .. str .. finish
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
            return table.concat(parts)
        end)
    end
end

return M
