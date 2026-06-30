--- Width-adaptive (flexible) component layout.
---
--- A flexible component holds an ordered list of rendered options, widest
--- first, and picks one to fit the available width. Because fitting is a global
--- decision over the whole line — multiple flexible components share one width
--- budget and contract in priority order — it cannot be expressed as
--- independent per-component memoization. Instead each flexible component
--- registers itself (with a per-window picked-index signal) into a registry
--- owned by the render scope, and the driver runs `fit` after rendering: it
--- measures the line, adjusts the picked indices, and lets the reactive system
--- recompute just the affected fragments.
---
--- The priority model matches heirline's classic behaviour: lower-priority
--- groups contract first, and a flexible nested inside another derives its
--- priority from the parent so inner components shrink one step after the outer
--- one. Nesting is tracked through a parent link recorded as the tree is built.
---@class heirline.Flexible
local M = {}

local r = require("heirline.reactive")
local count_chars = require("heirline.utils").count_chars

---@class heirline.flexible.Entry
---@field priority? integer Declared priority; nil for nested components that derive it.
---@field parent? heirline.flexible.Entry The enclosing flexible component, if any.
---@field options (fun(): string)[] Rendered option getters, widest first.
---@field count integer Number of options.
---@field index fun(): integer Getter for the currently picked option index.
---@field set_index fun(i: integer) Setter for the picked option index.

---@class heirline.flexible.Registry
---@field entries heirline.flexible.Entry[] Flexible components in tree pre-order.
---@field register fun(entry: heirline.flexible.Entry) Record a component under the current parent.
---@field push fun(entry: heirline.flexible.Entry) Enter a component's children.
---@field pop fun() Leave a component's children.

--- Create a registry for one render scope. A flexible component calls
--- `register` then `push` before instantiating its options and `pop` after, so
--- nested components are linked to their parent.
---@return heirline.flexible.Registry
function M.new_registry()
    local entries = {}
    local stack = {}
    return {
        entries = entries,
        register = function(entry)
            entry.parent = stack[#stack]
            entries[#entries + 1] = entry
        end,
        push = function(entry)
            stack[#stack + 1] = entry
        end,
        pop = function()
            stack[#stack] = nil
        end,
    }
end

--- Whether `ancestor` encloses `node` anywhere up the parent chain.
---@param ancestor heirline.flexible.Entry
---@param node heirline.flexible.Entry
---@return boolean
local function is_ancestor(ancestor, node)
    local parent = node.parent
    while parent do
        if parent == ancestor then
            return true
        end
        parent = parent.parent
    end
    return false
end

--- Display width of an entry's option `i`.
---@param entry heirline.flexible.Entry
---@param i integer
---@return integer
local function width(entry, i)
    return count_chars(entry.options[i]())
end

--- Advance an entry to its next (narrower) option, returning the previous index
--- or nil when already at the narrowest.
---@param entry heirline.flexible.Entry
---@return integer?
local function next_child(entry)
    local i = entry.index()
    if i + 1 > entry.count then
        return nil
    end
    entry.set_index(i + 1)
    return i
end

--- Step an entry back to its previous (wider) option, returning the previous
--- index or nil when already at the widest.
---@param entry heirline.flexible.Entry
---@return integer?
local function prev_child(entry)
    local i = entry.index()
    if i - 1 < 1 then
        return nil
    end
    entry.set_index(i - 1)
    return i
end

--- Partition the entries into priority groups, deriving the priority of nested
--- components from their ancestors, and return the groups together with their
--- priorities sorted for the given direction (`mode` is -1 to contract,
--- +1 to expand).
---@param entries heirline.flexible.Entry[]
---@param mode integer
---@return table<integer, heirline.flexible.Entry[]>, integer[]
local function group(entries, mode)
    local groups = {}
    local cur_priority, prev_entry, prev_parent
    for _, entry in ipairs(entries) do
        local priority
        if prev_entry and is_ancestor(prev_entry, entry) then
            prev_parent = prev_entry
            priority = cur_priority + mode
        elseif prev_parent and is_ancestor(prev_parent, entry) then
            priority = cur_priority
        else
            priority = entry.priority or 0
        end
        prev_entry = entry
        cur_priority = priority
        groups[priority] = groups[priority] or {}
        table.insert(groups[priority], entry)
    end

    local priorities = vim.tbl_keys(groups)
    table.sort(priorities, mode == -1 and function(a, b)
        return a < b
    end or function(a, b)
        return a > b
    end)
    return groups, priorities
end

--- Adjust the registry's picked indices so the line fits `max_width`.
---
--- When the line is too wide, contract groups from the lowest priority up; when
--- there is spare room, expand from the highest priority down, backing off one
--- step before an expansion would overflow. Index changes flow through the
--- per-window signals, so re-reading the line recomputes only the affected
--- flexible fragments.
---@param registry heirline.flexible.Registry
---@param out string The line as currently rendered.
---@param max_width integer The width to fit within.
function M.fit(registry, out, max_width)
    local entries = registry.entries
    if #entries == 0 then
        return
    end

    r.batch(function()
        local stl_len = count_chars(out)

        if stl_len > max_width then
            local groups, priorities = group(entries, -1)
            local saved = 0
            for _, p in ipairs(priorities) do
                while true do
                    local exhausted = true
                    for _, entry in ipairs(groups[p]) do
                        local prev_index = next_child(entry)
                        if prev_index then
                            exhausted = false
                            saved = saved + (width(entry, prev_index) - width(entry, prev_index + 1))
                        end
                    end
                    if stl_len - saved <= max_width then
                        return
                    end
                    if exhausted then
                        break
                    end
                end
            end
        elseif stl_len < max_width then
            local groups, priorities = group(entries, 1)
            local gained = 0
            for _, p in ipairs(priorities) do
                while true do
                    local exhausted = true
                    for _, entry in ipairs(groups[p]) do
                        local prev_index = prev_child(entry)
                        if prev_index then
                            exhausted = false
                            gained = gained + (width(entry, prev_index - 1) - width(entry, prev_index))
                        end
                    end
                    if stl_len + gained > max_width then
                        -- This step overflows; undo it for the whole group.
                        for _, entry in ipairs(groups[p]) do
                            next_child(entry)
                        end
                        return
                    end
                    if exhausted then
                        break
                    end
                end
            end
        end
    end)
end

return M
