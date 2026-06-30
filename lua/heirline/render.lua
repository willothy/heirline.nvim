--- Per-window render driver for a single line (statusline, winbar, tabline or
--- statuscolumn).
---
--- Each window gets its own reactive scope holding the component tree's memos,
--- so per-window output is cached independently. Rendering is pull-based: the
--- heavy work happens when Neovim evaluates the line (in the correct window
--- context), and only the memos whose signals changed are recomputed. A signal
--- change does not, by itself, compute anything here — it marks the relevant
--- memos dirty; the line is repainted because the reactive source that changed
--- requested a redraw, after which `eval` recomputes just the dirty fragments.
---@class heirline.Render
local M = {}

local r = require("heirline.reactive")

--- Autocommand group used to drop a window's scope when the window closes.
---@type integer?
local augroup = nil

---@return integer
local function ensure_augroup()
    if not augroup then
        augroup = vim.api.nvim_create_augroup("HeirlineRenderScopes", { clear = true })
    end
    return augroup
end

--- A global generation counter every line's root highlight subscribes to.
--- Bumping it invalidates the highlight chain of every component, forcing a
--- full re-render. Used to recover after the colorscheme (and therefore the
--- highlight definitions every cached fragment refers to) changes.
local generation_get, generation_set = r.signal(0)

--- Invalidate every component's highlight chain across all lines and windows,
--- forcing a full re-render on the next eval.
function M.invalidate()
    generation_set(generation_get() + 1)
end

---@class heirline.render.Scope
---@field dispose fun() Tears down the scope's reactive tree.
---@field get fun(): string Returns the (memoised) rendered line for the window.
---@field buf integer The buffer the scope was instantiated for.
---@field set_line? fun(lnum: integer, relnum: integer, virtnum: integer) Statuscolumn only: publish the line being drawn.

---@class heirline.RenderOpts
---@field hl? HeirlineHighlight|string|fun(): (HeirlineHighlight|string|nil) Root inherited highlight.
---@field global? boolean Render a single shared scope (for the tabline) instead of one per window.
---@field statuscolumn? boolean Render per screen line: expose reactive `lnum`/`relnum`/`virtnum` on the context, set from `v:lnum`/`v:relnum`/`v:virtnum` before each eval.

--- Create a render driver for `component`.
---
--- Returns a small record of closures: `eval(win)` renders the line for a
--- window (creating or rebuilding its scope as needed), and `dispose_win` /
--- `dispose_all` tear scopes down.
---@param component fun(ctx: heirline.Context): fun(): string
---@param opts? heirline.RenderOpts
---@return { eval: fun(win?: integer): string, dispose_win: fun(win: integer), dispose_all: fun() }
function M.new(component, opts)
    opts = opts or {}
    local root_hl = opts.hl
    local global = opts.global == true
    local statuscolumn = opts.statuscolumn == true

    --- Live scopes keyed by window id (or the constant `0` in global mode).
    ---@type table<integer, heirline.render.Scope>
    local scopes = {}

    --- Build the reactive scope for a window/buffer pair.
    ---@param win integer
    ---@param buf integer
    ---@return heirline.render.Scope
    local function instantiate(win, buf)
        local scope
        r.root(function(dispose)
            local hl = r.memo(function()
                -- Subscribe to the global generation so a colorscheme change
                -- invalidates this root highlight and, transitively, every
                -- component's merged highlight that inherits from it.
                generation_get()
                local value = root_hl
                if type(value) == "function" then
                    value = value()
                end
                return value or {}
            end)
            local ctx = { win = win, buf = buf, hl = hl }

            -- For the statuscolumn, the line being drawn is reactive state: the
            -- driver republishes it before every per-line eval, so only the
            -- components that read it recompute while the rest stay cached.
            local set_line
            if statuscolumn then
                local lnum_get, lnum_set = r.signal(0)
                local relnum_get, relnum_set = r.signal(0)
                local virtnum_get, virtnum_set = r.signal(0)
                ctx.lnum = lnum_get
                ctx.relnum = relnum_get
                ctx.virtnum = virtnum_get
                set_line = function(lnum, relnum, virtnum)
                    r.batch(function()
                        lnum_set(lnum)
                        relnum_set(relnum)
                        virtnum_set(virtnum)
                    end)
                end
            end

            local output = component(ctx)
            scope = { dispose = dispose, get = output, buf = buf, set_line = set_line }
        end)
        return scope
    end

    --- Render the line for `win`, defaulting to the current window. The scope is
    --- rebuilt if the window now displays a different buffer, keeping `ctx.buf`
    --- accurate. A render error is contained so it cannot break Neovim's redraw.
    ---@param win? integer
    ---@return string
    local function eval(win)
        win = win or vim.api.nvim_get_current_win()
        local key = global and 0 or win
        local buf = vim.api.nvim_win_get_buf(win)

        local scope = scopes[key]
        if scope and scope.buf ~= buf then
            scope.dispose()
            scope = nil
            scopes[key] = nil
        end
        if not scope then
            scope = instantiate(win, buf)
            scopes[key] = scope
        end

        if scope.set_line then
            scope.set_line(vim.v.lnum, vim.v.relnum, vim.v.virtnum)
        end

        local ok, result = pcall(scope.get)
        if not ok then
            return ""
        end
        return result
    end

    --- Dispose the scope for a single window.
    ---@param win integer
    local function dispose_win(win)
        local scope = scopes[win]
        if scope then
            scope.dispose()
            scopes[win] = nil
        end
    end

    --- Dispose every live scope.
    local function dispose_all()
        for key, scope in pairs(scopes) do
            scope.dispose()
            scopes[key] = nil
        end
    end

    -- Reap a window's scope when it closes so disposed windows do not leak
    -- reactive nodes or their autocommand-backed sources.
    vim.api.nvim_create_autocmd("WinClosed", {
        group = ensure_augroup(),
        desc = "heirline: dispose render scope for closed window",
        callback = function(args)
            local closed = tonumber(args.match)
            if closed then
                dispose_win(closed)
            end
        end,
    })

    return { eval = eval, dispose_win = dispose_win, dispose_all = dispose_all }
end

return M
