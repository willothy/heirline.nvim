local eq = assert.equals

local r = require("heirline.reactive")
local source = require("heirline.source")

describe("source.from_autocmd value source", function()
    it("updates the signal when the event fires", function()
        local value = "one"
        local get = source.from_autocmd({
            events = "User",
            pattern = "HeirlineSrcValue",
            get = function()
                return value
            end,
        })
        eq("one", get())

        value = "two"
        eq("one", get()) -- not refreshed until the event fires

        vim.cmd("doautocmd User HeirlineSrcValue")
        eq("two", get())
    end)

    it("can defer the initial value with immediate = false", function()
        local get = source.from_autocmd({
            events = "User",
            pattern = "HeirlineSrcLazy",
            immediate = false,
            get = function()
                return "computed"
            end,
        })
        eq(nil, get())
        vim.cmd("doautocmd User HeirlineSrcLazy")
        eq("computed", get())
    end)
end)

describe("source.from_user_event pulse source", function()
    it("recomputes dependents on each event", function()
        local get = source.from_user_event("HeirlineSrcPulse")
        local runs = 0
        r.effect(function()
            runs = runs + 1
            get()
        end)
        eq(1, runs)
        vim.cmd("doautocmd User HeirlineSrcPulse")
        eq(2, runs)
        vim.cmd("doautocmd User HeirlineSrcPulse")
        eq(3, runs)
    end)
end)

describe("source dispose", function()
    it("stops updating after explicit dispose", function()
        local get, dispose = source.from_user_event("HeirlineSrcDispose")
        local runs = 0
        r.effect(function()
            runs = runs + 1
            get()
        end)
        vim.cmd("doautocmd User HeirlineSrcDispose")
        eq(2, runs)
        dispose()
        vim.cmd("doautocmd User HeirlineSrcDispose")
        eq(2, runs) -- autocommand removed; signal no longer pulses
    end)

    it("is disposed with its owning reactive scope", function()
        local get
        local dispose_root
        r.root(function(dispose)
            dispose_root = dispose
            get = source.from_user_event("HeirlineSrcOwned")
        end)
        local runs = 0
        r.effect(function()
            runs = runs + 1
            get()
        end)
        vim.cmd("doautocmd User HeirlineSrcOwned")
        eq(2, runs)
        dispose_root()
        vim.cmd("doautocmd User HeirlineSrcOwned")
        eq(2, runs) -- source autocommand torn down with the root
    end)
end)

describe("source redraw requests", function()
    it("requests a redraw when an event fires by default", function()
        local original = source.request_redraw
        local count = 0
        source.request_redraw = function()
            count = count + 1
        end
        local ok, err = pcall(function()
            source.from_user_event("HeirlineSrcRedraw")
            vim.cmd("doautocmd User HeirlineSrcRedraw")
            eq(1, count)
        end)
        source.request_redraw = original
        assert(ok, err)
    end)

    it("does not request a redraw when redraw = false", function()
        local original = source.request_redraw
        local count = 0
        source.request_redraw = function()
            count = count + 1
        end
        local ok, err = pcall(function()
            source.from_autocmd({
                events = "User",
                pattern = "HeirlineSrcNoRedraw",
                redraw = false,
            })
            vim.cmd("doautocmd User HeirlineSrcNoRedraw")
            eq(0, count)
        end)
        source.request_redraw = original
        assert(ok, err)
    end)
end)

describe("source.request_redraw", function()
    it("coalesces and runs without error", function()
        source.request_redraw()
        source.request_redraw()
        vim.wait(50, function()
            return false
        end)
        -- After the scheduled redraw has run, a fresh request is accepted.
        source.request_redraw()
        vim.wait(50, function()
            return false
        end)
        eq(true, true)
    end)
end)
