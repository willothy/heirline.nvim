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
