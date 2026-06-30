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

describe("buflist", function()
    -- Render a buflist and return its visible text (markup stripped).
    local function display(rd, win)
        return vim.api.nvim_eval_statusline(rd.eval(win), { winid = win }).str
    end

    local function make_bufs(n)
        local bufs = {}
        for i = 1, n do
            bufs[i] = vim.api.nvim_create_buf(true, false)
        end
        return bufs
    end

    -- One character per buffer: "O" when active, "o" otherwise.
    local marker = function(ctx)
        return c.text(function()
            return ctx.is_active() and "O" or "o"
        end)(ctx)
    end

    it("renders every buffer and marks the active one", function()
        local bufs = make_bufs(4)
        local rd = render.new(lists.buflist(marker, {
            buffers = function()
                return bufs
            end,
        }))

        eq("oooo", display(rd, curwin())) -- none of these is current yet

        vim.api.nvim_set_current_buf(bufs[2])
        eq("oOoo", display(rd, curwin()))

        rd.dispose_all()
        for _, b in ipairs(bufs) do
            pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
    end)

    it("pages to fit the width and shows the active buffer's page", function()
        local bufs = make_bufs(4)
        -- Width 3 leaves room for one buffer between the two 1-column markers.
        local rd = render.new(lists.buflist(marker, {
            buffers = function()
                return bufs
            end,
        }), {
            width = function()
                return 3
            end,
        })

        vim.api.nvim_set_current_buf(bufs[2])
        -- The active buffer sits on an inner page, so both markers show.
        eq("<O>", display(rd, curwin()))

        vim.api.nvim_set_current_buf(bufs[1])
        -- First buffer: only the trailing marker shows.
        eq("O>", display(rd, curwin()))

        rd.dispose_all()
        for _, b in ipairs(bufs) do
            pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
    end)
end)
