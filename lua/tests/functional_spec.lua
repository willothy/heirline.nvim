local eq = assert.equals

local h = require("heirline")
local c = require("heirline.component")
local r = require("heirline.reactive")
local source = require("heirline.source")

--- Evaluate the configured statusline option for a window, returning the
--- visible string (highlight markup stripped).
local function eval(winid)
    winid = winid or 0
    return vim.api.nvim_eval_statusline(vim.o.statusline, { winid = winid, maxwidth = 0 }).str
end

local function win_getid(nr)
    local id = vim.fn.win_getid(nr)
    return id > 0 and id or error("window number not found")
end

describe("setup", function()
    it("wires the statusline option to the reactive renderer", function()
        vim.cmd("wincmd o")
        h.setup({ statusline = c.text("hello") })
        eq("%{%v:lua.require'heirline'.eval_statusline()%}", vim.o.statusline)
        eq("hello", eval())
    end)

    it("renders a group of components", function()
        vim.cmd("wincmd o")
        h.setup({
            statusline = c.group({
                c.text("a"),
                c.text("b"),
                c.text("c"),
            }),
        })
        eq("abc", eval())
    end)
end)

describe("reactive statusline", function()
    it("reflects signal changes after a redraw", function()
        vim.cmd("wincmd o")
        local get, set = r.signal("one")
        h.setup({
            statusline = c.text(function()
                return get()
            end),
        })
        eq("one", eval())
        set("two")
        eq("two", eval())
    end)

    it("updates from an autocmd-backed source", function()
        vim.cmd("wincmd o")
        local value = "before"
        local src = source.from_autocmd({
            events = "User",
            pattern = "HeirlineFuncUpdate",
            get = function()
                return value
            end,
        })
        h.setup({
            statusline = c.text(function()
                return src()
            end),
        })
        eq("before", eval())

        value = "after"
        eq("before", eval()) -- not refreshed until the event fires

        vim.cmd("doautocmd User HeirlineFuncUpdate")
        eq("after", eval())
        vim.cmd("au! User HeirlineFuncUpdate")
    end)

    it("renders each window with its own context", function()
        vim.cmd("wincmd o")
        h.setup({
            statusline = c.text(function(ctx)
                return "win:" .. ctx.win
            end),
        })
        vim.cmd("split")
        local w1 = win_getid(1)
        local w2 = win_getid(2)
        eq("win:" .. w1, eval(w1))
        eq("win:" .. w2, eval(w2))
        vim.cmd("wincmd o")
    end)
end)

describe("tabline", function()
    it("renders a single shared scope", function()
        vim.cmd("wincmd o")
        h.setup({ tabline = c.text("tabs") })
        eq("%{%v:lua.require'heirline'.eval_tabline()%}", vim.o.tabline)
        eq("tabs", vim.api.nvim_eval_statusline(vim.o.tabline, { winid = 0, maxwidth = 0 }).str)
    end)
end)

describe("colorscheme", function()
    it("re-registers highlight groups after a colorscheme change", function()
        vim.cmd("wincmd o")
        h.setup({
            statusline = c.text("x", { hl = { fg = "#abcdef", bold = true } }),
        })
        eval()
        -- The component registered at least one highlight group.
        assert(next(h.get_highlights()) ~= nil)

        vim.cmd("doautocmd ColorScheme")
        -- The cache was cleared and scopes disposed by the handler.
        eq(nil, next(h.get_highlights()))

        -- Re-rendering rebuilds the trees and re-registers the groups.
        eval()
        assert(next(h.get_highlights()) ~= nil)
    end)
end)

describe("statuscolumn", function()
    it("renders each line from its reactive line number", function()
        vim.cmd("wincmd o")
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "l1", "l2", "l3", "l4", "l5" })
        h.setup({
            statuscolumn = c.text(function(ctx)
                return ctx.lnum() .. " "
            end),
        })
        eq("%{%v:lua.require'heirline'.eval_statuscolumn()%}", vim.o.statuscolumn)

        local function col(lnum)
            return vim.api.nvim_eval_statusline(vim.o.statuscolumn, {
                winid = 0,
                use_statuscol_lnum = lnum,
            }).str
        end

        -- Each line gets its own value; the per-window cache does not pin a
        -- single line's result to the whole column.
        eq("1 ", col(1))
        eq("3 ", col(3))
        eq("5 ", col(5))
        eq("2 ", col(2))
    end)

    it("exposes relnum to components", function()
        vim.cmd("wincmd o")
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a", "b", "c" })
        h.setup({
            statuscolumn = c.text(function(ctx)
                return ctx.lnum() .. ":" .. ctx.relnum() .. " "
            end),
        })
        local out = vim.api.nvim_eval_statusline(vim.o.statuscolumn, {
            winid = 0,
            use_statuscol_lnum = 2,
        }).str
        -- v:lnum is the absolute line; v:relnum is its distance from the cursor.
        eq("2:", out:sub(1, 2))
    end)
end)
