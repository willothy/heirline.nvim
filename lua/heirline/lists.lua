--- Buffer and tab list builders.
---
--- These build dynamic statusline/tabline sections from the open buffers or
--- tabpages, on top of the reactive `list` primitive. Each entry is rendered by
--- a user-supplied component template that reads per-entry state (such as the
--- buffer number or whether the tab is active) from its context.
---@class heirline.Lists
local M = {}

local component = require("heirline.component")
local signal = require("heirline.signal")

--- Shallow-copy a context and overlay the given fields, so an entry component
--- inherits the surrounding context while gaining per-entry information.
---@param ctx heirline.Context
---@param fields table
---@return heirline.Context
local function extend_ctx(ctx, fields)
    local child = {}
    for k, v in pairs(ctx) do
        child[k] = v
    end
    for k, v in pairs(fields) do
        child[k] = v
    end
    return child
end

---@class heirline.TablistOpts
---@field hl? heirline.HlSpec
---@field condition? heirline.Condition

--- Build a tab list that renders every tabpage with `tab_component`.
---
--- Each tab's component receives a context extended with the `tabpage` handle
--- and reactive getters `tabnr()` (the tab's current position number) and
--- `is_active()` (whether it is the current tab). The list and these values
--- update as tabs are created, closed, or switched.
---@param tab_component fun(ctx: heirline.Context): fun(): string
---@param opts? heirline.TablistOpts
---@return fun(ctx: heirline.Context): fun(): string
function M.tablist(tab_component, opts)
    opts = opts or {}
    return component.list({
        hl = opts.hl,
        condition = opts.condition,
        items = function()
            signal.on_tab_change()() -- subscribe to tab create/close/switch
            return vim.api.nvim_list_tabpages()
        end,
        key = function(tabpage)
            return tabpage
        end,
        render = function(tabpage)
            return function(ctx)
                return tab_component(extend_ctx(ctx, {
                    tabpage = tabpage,
                    tabnr = function()
                        signal.on_tab_change()() -- renumber on create/close
                        return vim.api.nvim_tabpage_get_number(tabpage)
                    end,
                    is_active = function()
                        signal.on_tab_change()() -- recompute when focus changes
                        return tabpage == vim.api.nvim_get_current_tabpage()
                    end,
                }))
            end
        end,
    })
end

return M
