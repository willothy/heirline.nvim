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
local flexible = require("heirline.flexible")
local count_chars = require("heirline.utils").count_chars

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

---@class heirline.render.Scope
---@field dispose fun() Tears down the scope's reactive tree.
---@field get fun(): string Returns the (memoised) rendered line for the window.
---@field buf integer The buffer the scope was instantiated for.
---@field set_line? fun(lnum: integer, relnum: integer, virtnum: integer) Statuscolumn only: publish the line being drawn.
---@field flex heirline.flexible.Registry The scope's flexible-component registry.
---@field paging { entries: { fragment: fun(): string, apply: fun(width: integer) }[] } Buffer lists needing a width-fitting pass.

---@class heirline.RenderOpts
---@field hl? HeirlineHighlight|string|fun(): (HeirlineHighlight|string|nil) Root inherited highlight.
---@field global? boolean Render a single shared scope (for the tabline) instead of one per window.
---@field statuscolumn? boolean Render per screen line: expose reactive `lnum`/`relnum`/`virtnum` on the context, set from `v:lnum`/`v:relnum`/`v:virtnum` before each eval.
---@field width? fun(win: integer): integer The width flexible components fit within; defaults to the window width (or `&columns` in global mode).

--- Fit a buffer list into the width left after the rest of the line.
---
--- For each registered paging entry, the available width is the budget minus
--- everything on the line that is not the buffer list itself; publishing it lets
--- the list re-page to show the buffers that fit around its truncation markers.
---@param scope heirline.render.Scope
---@param line string The line as currently rendered.
---@param budget integer The total width to fit within.
local function apply_paging(scope, line, budget)
    local full = count_chars(line)
    for _, entry in ipairs(scope.paging.entries) do
        local own = count_chars(entry.fragment())
        entry.apply(budget - (full - own))
    end
end

--- Run the width-adaptation passes for a scope and return the re-rendered line.
---
--- Flexible components are fitted first; the buffer lists are then paged into
--- the remaining space; finally the flexible components are re-fitted, since
--- paging can change the line's width. Each pass re-reads the line so only the
--- fragments whose picks changed recompute.
---@param scope heirline.render.Scope
---@param line string
---@param budget integer
---@param has_flex boolean
---@param has_paging boolean
---@return string
local function adapt(scope, line, budget, has_flex, has_paging)
    if has_flex then
        flexible.fit(scope.flex, line, budget)
        line = scope.get()
    end
    if has_paging then
        apply_paging(scope, line, budget)
        line = scope.get()
        if has_flex then
            flexible.fit(scope.flex, line, budget)
            line = scope.get()
        end
    end
    return line
end

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
    local width = opts.width
        or function(win)
            return global and vim.o.columns or vim.api.nvim_win_get_width(win)
        end

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
                local value = root_hl
                if type(value) == "function" then
                    value = value()
                end
                return value or {}
            end)
            local registry = flexible.new_registry()
            -- Paging entries (buffer lists) that need to fit the width left over
            -- after the rest of the line is measured.
            local paging = { entries = {} }
            local ctx = { win = win, buf = buf, hl = hl, flex = registry, paging = paging }

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
            scope = {
                dispose = dispose,
                get = output,
                buf = buf,
                set_line = set_line,
                flex = registry,
                paging = paging,
            }
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

        local has_flex = #scope.flex.entries > 0
        local has_paging = #scope.paging.entries > 0
        if has_flex or has_paging then
            local ok2, adapted = pcall(adapt, scope, result, width(win), has_flex, has_paging)
            if ok2 then
                result = adapted
            end
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
