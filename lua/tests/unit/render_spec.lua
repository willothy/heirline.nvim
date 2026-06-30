local eq = assert.equals

local r = require("heirline.reactive")
local c = require("heirline.component")
local render = require("heirline.render")

local function curwin()
    return vim.api.nvim_get_current_win()
end

describe("component rendering", function()
    it("renders a static text component", function()
        local rd = render.new(c.text("hello"))
        eq("hello", rd.eval(curwin()))
        rd.dispose_all()
    end)

    it("renders a group by concatenating children", function()
        local rd = render.new(c.group({
            c.text("a"),
            c.text("b"),
            c.text("c"),
        }))
        eq("abc", rd.eval(curwin()))
        rd.dispose_all()
    end)

    it("reflects signal changes on the next eval", function()
        local get, set = r.signal("one")
        local rd = render.new(c.text(function()
            return get()
        end))
        eq("one", rd.eval(curwin()))
        set("two")
        eq("two", rd.eval(curwin()))
        rd.dispose_all()
    end)

    it("hides a component whose condition is false", function()
        local show_get, show_set = r.signal(true)
        local rd = render.new(c.group({
            c.text("X", { condition = function()
                return show_get()
            end }),
            c.text("Y"),
        }))
        eq("XY", rd.eval(curwin()))
        show_set(false)
        eq("Y", rd.eval(curwin()))
        show_set(true)
        eq("XY", rd.eval(curwin()))
        rd.dispose_all()
    end)
end)

describe("fine-grained recomputation", function()
    it("only recomputes the component whose dependency changed", function()
        local a_get, a_set = r.signal("a")
        local b_get, b_set = r.signal("b")
        local a_runs, b_runs = 0, 0

        local rd = render.new(c.group({
            c.text(function()
                a_runs = a_runs + 1
                return a_get()
            end),
            c.text(function()
                b_runs = b_runs + 1
                return b_get()
            end),
        }))

        eq("ab", rd.eval(curwin()))
        eq(1, a_runs)
        eq(1, b_runs)

        b_set("B")
        eq("aB", rd.eval(curwin()))
        eq(1, a_runs) -- unchanged: a's provider was not re-run
        eq(2, b_runs)

        a_set("A")
        eq("AB", rd.eval(curwin()))
        eq(2, a_runs)
        eq(2, b_runs)

        rd.dispose_all()
    end)

    it("does not recompute anything when nothing changed", function()
        local get = r.signal("v")
        local runs = 0
        local rd = render.new(c.text(function()
            runs = runs + 1
            return get()
        end))
        eq("v", rd.eval(curwin()))
        eq(1, runs)
        eq("v", rd.eval(curwin())) -- cached
        eq("v", rd.eval(curwin()))
        eq(1, runs)
        rd.dispose_all()
    end)
end)

describe("highlight inheritance", function()
    it("wraps text in a highlight and inherits down groups", function()
        local rd = render.new(c.group({
            c.text("x", { hl = { fg = "#ff0000" } }),
        }, { hl = { bg = "#00ff00", bold = true } }))
        local out = rd.eval(curwin())
        -- The rendered fragment carries a highlight group reference and the text.
        eq(true, out:find("%%#") ~= nil)
        eq(true, out:find("x") ~= nil)
        -- The visible text resolves to exactly "x".
        eq("x", vim.api.nvim_eval_statusline(out, { winid = curwin() }).str)
        rd.dispose_all()
    end)
end)

describe("per-window scopes", function()
    it("caches output independently per window", function()
        vim.cmd("wincmd o")
        local w1 = curwin()
        vim.cmd("split")
        local w2 = curwin()

        local runs = {}
        local rd = render.new(c.text(function(ctx)
            runs[ctx.win] = (runs[ctx.win] or 0) + 1
            return "win:" .. ctx.win
        end))

        eq("win:" .. w1, rd.eval(w1))
        eq("win:" .. w2, rd.eval(w2))
        eq(1, runs[w1])
        eq(1, runs[w2])

        -- Re-evaluating without changes recomputes neither window.
        rd.eval(w1)
        rd.eval(w2)
        eq(1, runs[w1])
        eq(1, runs[w2])

        rd.dispose_all()
        vim.cmd("wincmd o")
    end)
end)
