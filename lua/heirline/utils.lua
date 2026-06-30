--- Small shared utilities used across heirline's reactive modules.
---@class heirline.Utils
local M = {}

local nvim_eval_statusline = vim.api.nvim_eval_statusline

--- Look up a highlight definition by name without creating it if it is absent.
---@param name string
---@return table
function M.get_highlight(name)
    return vim.api.nvim_get_hl(0, { name = name, link = false, create = false })
end

--- Measure the display width of a statusline format string.
---@param str string
---@return integer
function M.count_chars(str)
    return nvim_eval_statusline(str, { winid = 0, maxwidth = 0 }).width
end

return M
