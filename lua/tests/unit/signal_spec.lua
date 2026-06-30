local eq = assert.equals

local r = require("heirline.reactive")
local signal = require("heirline.signal")

describe("singleton source lifecycle", function()
    -- Runs first so the on_lsp_change singleton is created inside the effect
    -- below: it must outlive that computation's re-runs.
    it("keeps a singleton source alive when its first reader re-runs", function()
        local force, set_force = r.signal(0)
        local runs = 0
        r.effect(function()
            force()
            signal.on_lsp_change()() -- first read creates the singleton source
            runs = runs + 1
        end)
        eq(1, runs)

        set_force(1) -- re-run the effect; the source must not be disposed with it
        eq(2, runs)

        vim.api.nvim_exec_autocmds("LspAttach", { data = {} })
        eq(3, runs) -- the source survived and still pulses
    end)
end)

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
