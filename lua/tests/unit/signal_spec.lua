local eq = assert.equals

local r = require("heirline.reactive")
local signal = require("heirline.signal")

describe("signal.mode", function()
    it("returns a singleton getter for the current mode string", function()
        local mode = signal.mode()
        eq("string", type(mode()))
        eq(mode, signal.mode()) -- same underlying source on repeated access
    end)
end)

describe("signal event triggers", function()
    it("recomputes dependents when the backing events fire", function()
        local trigger = signal.on_buf_change()
        local runs = 0
        local dispose = r.effect(function()
            runs = runs + 1
            trigger()
        end)
        eq(1, runs)
        vim.cmd("doautocmd BufEnter")
        eq(2, runs)
        dispose()
    end)
end)

describe("signal.is_active", function()
    it("compares ctx.win against the focused window", function()
        vim.g.actual_curwin = "5"
        eq(true, signal.is_active({ win = 5 }))
        eq(false, signal.is_active({ win = 6 }))
        vim.g.actual_curwin = "6"
        eq(false, signal.is_active({ win = 5 }))
        eq(true, signal.is_active({ win = 6 }))
    end)
end)
