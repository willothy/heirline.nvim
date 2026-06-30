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
local source = require("heirline.source")
local r = require("heirline.reactive")
local count_chars = require("heirline.utils").count_chars

--- Distinguishes the global click handlers of multiple buffer lists.
local buflist_counter = 0

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

--- The default buffer source: every listed buffer.
---@return integer[]
local function listed_buffers()
    return vim.tbl_filter(function(bufnr)
        return vim.bo[bufnr].buflisted
    end, vim.api.nvim_list_bufs())
end

--- Whether the given buffer is displayed in any window of the current tab.
---@param bufnr integer
---@return boolean
local function buffer_visible(bufnr)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(win) == bufnr then
            return true
        end
    end
    return false
end

---@class heirline.BuflistOpts
---@field left_trunc? string Marker shown when buffers precede the page (default "<").
---@field right_trunc? string Marker shown when buffers follow the page (default ">").
---@field buffers? fun(): integer[] Source of buffer numbers (default: all listed buffers).
---@field hl? heirline.HlSpec
---@field condition? heirline.Condition

--- Build a buffer list that renders every buffer with `buffer_component` and
--- pages it to fit the available width.
---
--- Each buffer's component receives a context carrying `bufnr` and reactive
--- `is_active()`/`is_visible()` getters. When the buffers do not all fit, the
--- list shows the page containing the active buffer, with clickable truncation
--- markers to move between pages; clicking locks the page until the next buffer
--- switch. The available width is computed by the render driver from the space
--- left over by the rest of the line.
---@param buffer_component fun(ctx: heirline.Context): fun(): string
---@param opts? heirline.BuflistOpts
---@return fun(ctx: heirline.Context): fun(): string
function M.buflist(buffer_component, opts)
    opts = opts or {}
    local buffers = opts.buffers or listed_buffers

    return function(ctx)
        buflist_counter = buflist_counter + 1
        local id = buflist_counter

        local page, set_page = r.signal(1)
        local forced, set_forced = r.signal(false)
        local available, set_available = r.signal(math.huge)

        -- A buffer switch releases a click-locked page so the list follows the
        -- active buffer again.
        local release = vim.api.nvim_create_autocmd("BufEnter", {
            callback = function()
                set_forced(false)
            end,
            desc = "heirline: release buffer list page lock",
        })
        r.on_cleanup(function()
            pcall(vim.api.nvim_del_autocmd, release)
        end)

        local left = component.text(opts.left_trunc or "<", {
            on_click = {
                name = "HeirlineBuflistPrev" .. id,
                callback = function()
                    set_forced(true)
                    set_page(math.max(1, page() - 1))
                    source.request_redraw()
                end,
            },
        })(ctx)
        local right = component.text(opts.right_trunc or ">", {
            on_click = {
                name = "HeirlineBuflistNext" .. id,
                callback = function()
                    set_forced(true)
                    set_page(page() + 1)
                    source.request_redraw()
                end,
            },
        })(ctx)

        --- Split the entries into pages, render the active or locked page, and
        --- frame it with truncation markers.
        ---@param entries heirline.list.Entry[]
        ---@return string
        local function page_layout(entries)
            local is_forced = forced()
            local maxwidth = available() - count_chars(left()) - count_chars(right())

            local pages = { {} }
            local current = pages[1]
            local length = 0
            local active_page
            local current_buf = vim.api.nvim_get_current_buf()
            for _, entry in ipairs(entries) do
                local w = count_chars(entry.get())
                if length + w > maxwidth and #current > 0 then
                    current = {}
                    pages[#pages + 1] = current
                    length = 0
                end
                current[#current + 1] = entry
                length = length + w
                if entry.key == current_buf then
                    active_page = #pages
                end
            end

            local index
            if is_forced then
                index = math.min(math.max(page(), 1), #pages)
            else
                index = active_page or 1
                -- Keep the stored page in sync without subscribing to it, so the
                -- next manual navigation starts from the visible page.
                if r.untrack(page) ~= index then
                    r.untrack(function()
                        set_page(index)
                    end)
                end
            end

            local parts = {}
            if index > 1 then
                parts[#parts + 1] = left()
            end
            for _, entry in ipairs(pages[index] or {}) do
                parts[#parts + 1] = entry.get()
            end
            if index < #pages then
                parts[#parts + 1] = right()
            end
            return table.concat(parts)
        end

        local list = component.list({
            hl = opts.hl,
            condition = opts.condition,
            items = function()
                signal.on_buflist_change()() -- buffers added/removed/entered
                return vim.tbl_filter(vim.api.nvim_buf_is_valid, buffers())
            end,
            key = function(bufnr)
                return bufnr
            end,
            render = function(bufnr)
                return function(c2)
                    return buffer_component(extend_ctx(c2, {
                        bufnr = bufnr,
                        is_active = function()
                            signal.on_buflist_change()()
                            return bufnr == vim.api.nvim_get_current_buf()
                        end,
                        is_visible = function()
                            signal.on_win_change()()
                            return buffer_visible(bufnr)
                        end,
                    }))
                end
            end,
            layout = page_layout,
        })

        local getter = list(ctx)

        -- Let the driver tell us how much width is left for the buffers after
        -- the rest of the line is accounted for.
        if ctx.paging then
            ctx.paging.entries[#ctx.paging.entries + 1] = {
                fragment = getter,
                apply = set_available,
            }
        end

        return getter
    end
end

return M
