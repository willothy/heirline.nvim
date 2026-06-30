local eq = assert.equals

local c = require("heirline.component")
local render = require("heirline.render")
local lists = require("heirline.lists")

local function curwin()
    return vim.api.nvim_get_current_win()
end

describe("tablist", function()
    it("renders each tab and tracks the active one", function()
        vim.cmd("silent! tabonly")

        local label = function(ctx)
            return c.text(function()
                if ctx.is_active() then
                    return "[" .. ctx.tabnr() .. "]"
                end
                return tostring(ctx.tabnr())
            end)(ctx)
        end

        local rd = render.new(lists.tablist(label), { global = true })

        eq("[1]", rd.eval(curwin()))

        vim.cmd("tabnew")
        eq("1[2]", rd.eval(curwin())) -- new tab is active

        vim.cmd("tabprevious")
        eq("[1]2", rd.eval(curwin())) -- focus moved back to tab 1

        vim.cmd("silent! tabonly")
        eq("[1]", rd.eval(curwin())) -- second tab closed

        rd.dispose_all()
    end)
end)
