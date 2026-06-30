--- heirline: a reactive statusline, winbar and tabline engine for Neovim.
---
--- Lines are authored as signal-first components (see `heirline.component`) and
--- rendered through per-window reactive scopes (see `heirline.render`). State
--- comes from reactive signals — typically driven by Neovim events through
--- `heirline.source` — so a change recomputes only the components that read it
--- and repaints once.
---@class heirline
local M = {}

local render = require("heirline.render")
local highlights = require("heirline.highlights")
local source = require("heirline.source")

--- The render driver for each configured line, keyed by line kind.
---@type table<string, { eval: fun(win?: integer): string, dispose_win: fun(win: integer), dispose_all: fun() }>
local lines = {}

--- The option expression that points a line at its evaluator.
local function line_expr(name)
    return "%{%v:lua.require'heirline'." .. name .. "()%}"
end

function M.reset_highlights()
    return highlights.reset_highlights()
end

function M.get_highlights()
    return highlights.get_highlights()
end

--- Load color aliases usable by name in component highlights.
---@param colors table<string, string|integer>|fun(): table<string, string|integer>
---@return nil
function M.load_colors(colors)
    colors = type(colors) == "function" and colors() or colors
    return highlights.load_colors(colors)
end

function M.clear_colors()
    return highlights.clear_colors()
end

--- Set the window-local winbar option on eligible windows.
---
--- A window opts out when `callback(args)` returns true (for example, on
--- special filetypes), or when it is only one line tall. This mirrors the
--- classic behaviour; only the rendering underneath is reactive.
---@param callback? fun(args: table): boolean?
local function setup_local_winbar_with_autocmd(callback)
    local expr = line_expr("eval_winbar")
    local group = vim.api.nvim_create_augroup("Heirline_init_winbar", { clear = true })
    vim.api.nvim_create_autocmd({ "VimEnter", "UIEnter", "BufWinEnter", "FileType", "TermOpen" }, {
        group = group,
        desc = "Heirline: set window-local winbar",
        callback = function(args)
            if args.event == "VimEnter" or args.event == "UIEnter" then
                for _, win in ipairs(vim.api.nvim_list_wins()) do
                    local win_args = vim.tbl_extend("force", args, { buf = vim.api.nvim_win_get_buf(win) })
                    if callback and callback(win_args) == true then
                        if vim.wo[win].winbar == expr then
                            vim.wo[win].winbar = ""
                        end
                    else
                        vim.wo[win].winbar = expr
                    end
                end
            end

            if callback and callback(args) == true then
                if vim.opt_local.winbar:get() == expr then
                    vim.opt_local.winbar = ""
                end
                return
            end

            if vim.api.nvim_win_get_height(0) > 1 then
                vim.opt_local.winbar = expr
            end
        end,
    })
end

---@class heirline.SetupConfig
---@field statusline? fun(ctx: heirline.Context): fun(): string
---@field winbar? fun(ctx: heirline.Context): fun(): string
---@field tabline? fun(ctx: heirline.Context): fun(): string
---@field statuscolumn? fun(ctx: heirline.Context): fun(): string
---@field opts? heirline.SetupOpts

---@class heirline.SetupOpts
---@field colors? table<string, string|integer>|fun(): table<string, string|integer>
---@field disable_winbar_cb? fun(args: table): boolean?

--- Configure heirline.
---
--- Each line is a component built with `heirline.component`. Calling `setup`
--- again replaces the previous configuration, disposing the old reactive
--- scopes first.
---@param config heirline.SetupConfig
function M.setup(config)
    config = config or {}
    vim.g.qf_disable_statusline = true

    -- Replace any previous configuration cleanly.
    for kind, line in pairs(lines) do
        line.dispose_all()
        lines[kind] = nil
    end

    M.reset_highlights()

    local opts = config.opts or {}
    if opts.colors then
        M.load_colors(opts.colors)
    end

    if config.statusline then
        lines.statusline = render.new(config.statusline)
        vim.o.statusline = line_expr("eval_statusline")
    end

    if config.winbar then
        lines.winbar = render.new(config.winbar)
        setup_local_winbar_with_autocmd(opts.disable_winbar_cb)
    end

    if config.tabline then
        lines.tabline = render.new(config.tabline, { global = true })
        vim.o.tabline = line_expr("eval_tabline")
    end

    if config.statuscolumn then
        lines.statuscolumn = render.new(config.statuscolumn, { statuscolumn = true })
        vim.o.statuscolumn = line_expr("eval_statuscolumn")
    end

    -- A colorscheme change rewrites the highlight definitions that cached
    -- fragments refer to. Reset the highlight cache and dispose every scope so
    -- the next eval rebuilds the component trees from scratch, re-registering
    -- the highlight groups. A rebuild (rather than signal-based invalidation)
    -- is used because unchanged highlight values would otherwise be cut off by
    -- the reactive system and never recompute.
    local group = vim.api.nvim_create_augroup("Heirline_update_autocmds", { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = group,
        desc = "Heirline: rebuild highlights after a colorscheme change",
        callback = function()
            M.reset_highlights()
            for _, line in pairs(lines) do
                line.dispose_all()
            end
            source.request_redraw()
        end,
    })
end

---@return string
function M.eval_statusline()
    local line = lines.statusline
    return line and line.eval(vim.api.nvim_get_current_win()) or ""
end

---@return string
function M.eval_winbar()
    local line = lines.winbar
    return line and line.eval(vim.api.nvim_get_current_win()) or ""
end

---@return string
function M.eval_tabline()
    local line = lines.tabline
    return line and line.eval(vim.api.nvim_get_current_win()) or ""
end

---@return string
function M.eval_statuscolumn()
    local line = lines.statuscolumn
    return line and line.eval(vim.api.nvim_get_current_win()) or ""
end

return M
