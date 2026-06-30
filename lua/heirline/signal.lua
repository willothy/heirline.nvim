--- Curated reactive sources for building statuslines.
---
--- These are thin, ready-made wrappers over `heirline.source` for the editor
--- state statuslines most often react to. Two shapes are provided:
---   * **Event triggers** (`on_*`): pulse signals that make any component
---     reading them recompute when the corresponding Neovim events fire. Pair
---     them with a context-specific read (for example, the cursor of `ctx.win`)
---     to get correct per-window values.
---   * **Value signals** (`mode`): signals that carry editor state directly.
---
--- Each accessor returns a process-wide singleton getter, created on first use,
--- so many components can share one underlying autocommand.
---@class heirline.Signal
local M = {}

local r = require("heirline.reactive")
local source = require("heirline.source")

--- Cache of singleton getters keyed by accessor name. The getters carry
--- different value types, so the map is typed by the function shape only.
---@type table<string, function>
local singletons = {}

--- Return the cached singleton for `key`, creating it with `factory` on first
--- use.
---
--- The factory runs inside a detached `root` so the source it creates lives for
--- the process, rather than being torn down with whatever computation happened
--- to read it first (a source's autocommand is otherwise disposed with the
--- scope that was active when `from_autocmd` registered its cleanup).
---@generic T
---@param key string
---@param factory fun(): fun(): T
---@return fun(): T
local function singleton(key, factory)
    local getter = singletons[key]
    if not getter then
        r.root(function()
            getter = factory()
        end)
        singletons[key] = getter
    end
    return getter
end

--- The current mode short-name (for example `n`, `i`, `v`, `niI`), updated on
--- every mode transition.
---@return fun(): string
function M.mode()
    return singleton("mode", function()
        return (source.from_autocmd({
            events = "ModeChanged",
            get = function()
                return vim.api.nvim_get_mode().mode
            end,
            desc = "heirline: current mode",
        }))
    end)
end

--- Recompute trigger for cursor movement (normal and insert).
---@return heirline.Trigger
function M.on_cursor_move()
    return singleton("on_cursor_move", function()
        return (source.from_autocmd({
            events = { "CursorMoved", "CursorMovedI" },
            desc = "heirline: cursor moved",
        }))
    end)
end

--- Recompute trigger for changes to the buffer shown in a window: switching
--- buffers, writing, or renaming.
---@return heirline.Trigger
function M.on_buf_change()
    return singleton("on_buf_change", function()
        return (source.from_autocmd({
            events = { "BufEnter", "BufWinEnter", "BufWritePost", "BufFilePost" },
            desc = "heirline: buffer changed",
        }))
    end)
end

--- Recompute trigger for the buffer list: buffers added, deleted, or entered.
---@return heirline.Trigger
function M.on_buflist_change()
    return singleton("on_buflist_change", function()
        return (source.from_autocmd({
            events = { "BufAdd", "BufDelete", "BufEnter", "BufLeave", "BufWinEnter" },
            desc = "heirline: buffer list changed",
        }))
    end)
end

--- Recompute trigger for the tab list: tabs created, closed, or switched.
---@return heirline.Trigger
function M.on_tab_change()
    return singleton("on_tab_change", function()
        return (source.from_autocmd({
            events = { "TabNew", "TabClosed", "TabEnter", "TabLeave" },
            desc = "heirline: tab list changed",
        }))
    end)
end

--- Recompute trigger for window focus and layout changes.
---@return heirline.Trigger
function M.on_win_change()
    return singleton("on_win_change", function()
        return (source.from_autocmd({
            events = { "WinEnter", "WinLeave", "WinNew", "WinClosed", "BufWinEnter" },
            desc = "heirline: window changed",
        }))
    end)
end

--- Recompute trigger for diagnostic updates.
---@return heirline.Trigger
function M.on_diagnostics_change()
    return singleton("on_diagnostics_change", function()
        return (source.from_autocmd({
            events = "DiagnosticChanged",
            desc = "heirline: diagnostics changed",
        }))
    end)
end

--- Recompute trigger for LSP attach/detach.
---@return heirline.Trigger
function M.on_lsp_change()
    return singleton("on_lsp_change", function()
        return (source.from_autocmd({
            events = { "LspAttach", "LspDetach" },
            desc = "heirline: lsp clients changed",
        }))
    end)
end

--- Whether `ctx.win` is the focused window, tracked reactively.
---
--- During a line's evaluation the window being drawn is the current window, so
--- the truly-focused window is read from `g:actual_curwin` rather than the
--- current-window API. Reading this subscribes the caller to window changes.
---@param ctx heirline.Context
---@return boolean
function M.is_active(ctx)
    M.on_win_change()() -- subscribe to focus changes
    return ctx.win == tonumber(vim.g.actual_curwin)
end

return M
