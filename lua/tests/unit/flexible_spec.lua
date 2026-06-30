local eq = assert.equals

local r = require("heirline.reactive")
local flexible = require("heirline.flexible")

--- Build a registry entry whose options have the given display widths.
local function make_entry(priority, widths)
    local index, set_index = r.signal(1)
    local options = {}
    for i, w in ipairs(widths) do
        local str = string.rep("x", w)
        options[i] = function()
            return str
        end
    end
    return {
        priority = priority,
        index = index,
        set_index = set_index,
        options = options,
        count = #widths,
    }
end

--- Concatenate the currently picked option of every entry.
local function line(entries)
    local parts = {}
    for _, entry in ipairs(entries) do
        parts[#parts + 1] = entry.options[entry.index()]()
    end
    return table.concat(parts)
end

describe("flexible.fit single component", function()
    it("keeps the widest option when it fits", function()
        local e = make_entry(1, { 40, 30, 10 })
        local reg = { entries = { e } }
        flexible.fit(reg, line(reg.entries), 40)
        eq(1, e.index())
    end)

    it("contracts to the widest option that fits", function()
        local e = make_entry(1, { 40, 30, 10 })
        local reg = { entries = { e } }
        flexible.fit(reg, line(reg.entries), 35)
        eq(2, e.index())
    end)

    it("contracts to the narrowest option when nothing fits", function()
        local e = make_entry(1, { 40, 30, 10 })
        local reg = { entries = { e } }
        flexible.fit(reg, line(reg.entries), 5)
        eq(3, e.index())
    end)

    it("expands to the widest option that fits when there is room", function()
        local e = make_entry(1, { 40, 30, 10 })
        local reg = { entries = { e } }
        e.set_index(3) -- start at the narrowest
        flexible.fit(reg, line(reg.entries), 35)
        eq(2, e.index()) -- 30 fits in 35, 40 does not
    end)
end)

describe("flexible.fit nested priority", function()
    it("contracts a nested component before its parent", function()
        local outer = make_entry(1, { 20, 10 })
        local inner = make_entry(nil, { 20, 10 })
        inner.parent = outer
        local reg = { entries = { outer, inner } } -- tree pre-order

        flexible.fit(reg, line(reg.entries), 30) -- from 40, shed 10
        eq(1, outer.index()) -- parent untouched
        eq(2, inner.index()) -- nested contracted first
    end)
end)
