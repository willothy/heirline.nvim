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

describe("on_click", function()
    it("wraps the fragment and registers a handler that receives the context", function()
        local seen
        local rd = render.new(c.text("btn", {
            on_click = {
                name = "HeirlineTestClick",
                callback = function(ctx, minwid, nclicks, button)
                    seen = { win = ctx.win, minwid = minwid, nclicks = nclicks, button = button }
                end,
            },
        }))
        local out = rd.eval(curwin())
        eq(true, out:find("@v:lua.HeirlineTestClick@", 1, true) ~= nil)
        eq(true, out:find("%X", 1, true) ~= nil)

        -- Vim would invoke the registered global on a mouse click.
        _G.HeirlineTestClick(7, 2, "r", "")
        eq(curwin(), seen.win)
        eq(7, seen.minwid)
        eq(2, seen.nclicks)
        eq("r", seen.button)

        rd.dispose_all()
        -- The handler is cleaned up with its scope.
        eq(nil, _G.HeirlineTestClick)
    end)
end)

describe("dynamic list", function()
    it("renders an item per entry and updates as the list changes", function()
        local items_get, items_set = r.signal({ 1, 2, 3 })
        local rd = render.new(c.list({
            items = function()
                return items_get()
            end,
            render = function(key)
                return c.text("[" .. key .. "]")
            end,
        }))
        eq("[1][2][3]", rd.eval(curwin()))
        items_set({ 1, 3 })
        eq("[1][3]", rd.eval(curwin()))
        items_set({ 1, 3, 4, 5 })
        eq("[1][3][4][5]", rd.eval(curwin()))
        rd.dispose_all()
    end)

    it("composes children through a custom layout", function()
        local items_get = r.signal({ "a", "b", "c", "d" })
        local rd = render.new(c.list({
            items = function()
                return items_get()
            end,
            render = function(key)
                return c.text(key)
            end,
            -- Render only the first two entries, wrapped in markers.
            layout = function(entries)
                local out = "<"
                for i = 1, math.min(2, #entries) do
                    out = out .. entries[i].get()
                end
                return out .. ">"
            end,
        }))
        eq("<ab>", rd.eval(curwin()))
        rd.dispose_all()
    end)

    it("disposes children whose keys disappear", function()
        local items_get, items_set = r.signal({ "a", "b", "c" })
        local cleaned = {}
        local rd = render.new(c.list({
            items = function()
                return items_get()
            end,
            render = function(key)
                return function(ctx)
                    r.on_cleanup(function()
                        cleaned[key] = true
                    end)
                    return c.text(key)(ctx)
                end
            end,
        }))
        eq("abc", rd.eval(curwin()))
        items_set({ "a", "c" })
        rd.eval(curwin())
        eq(true, cleaned["b"]) -- the dropped child's scope was disposed
        eq(nil, cleaned["a"])

        rd.dispose_all()
        -- Remaining children are disposed with the list scope.
        eq(true, cleaned["a"])
        eq(true, cleaned["c"])
    end)
end)

describe("flexible components", function()
    it("renders the widest option that fits the window", function()
        local rd = render.new(c.flexible(1, {
            c.text("AA"),
            c.text("B"),
        }))
        eq("AA", rd.eval(curwin())) -- two columns fit any window
        rd.dispose_all()
    end)

    it("contracts when the widest option overflows the window", function()
        local rd = render.new(c.flexible(1, {
            c.text(string.rep("A", 5000)),
            c.text("B"),
        }))
        -- 5000 columns cannot fit any real window, so it falls back to "B".
        eq("B", rd.eval(curwin()))
        rd.dispose_all()
    end)
end)

describe("surround", function()
    it("wraps a component in tinted delimiters", function()
        local rd = render.new(c.surround({ "[", "]" }, "#445566", c.text("x")))
        local out = rd.eval(curwin())
        -- Visible text is the body framed by the delimiters.
        eq("[x]", vim.api.nvim_eval_statusline(out, { winid = curwin() }).str)
        -- The delimiters carry a highlight (the tint).
        eq(true, out:find("%%#") ~= nil)
        rd.dispose_all()
    end)

    it("omits the tint when the color function returns nil", function()
        local rd = render.new(c.surround({ "(", ")" }, function()
            return nil
        end, c.text("y")))
        eq("(y)", vim.api.nvim_eval_statusline(rd.eval(curwin()), { winid = curwin() }).str)
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
