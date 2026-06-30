--- Neovim integration for the reactive core.
---
--- This module bridges Neovim's event model and the reactive graph in both
--- directions:
---   * `from_autocmd` turns one or more autocommands into a reactive signal, so
---     editor events (mode changes, buffer writes, diagnostics, user events,
---     ...) propagate into memos and effects automatically.
---   * `request_redraw` is the outbound side: reactive effects call it when the
---     rendered output changes, and it coalesces those calls into a single
---     scheduled repaint of every heirline-managed line.
---
--- Together these replace heirline's previous manual `update = { events }`
--- mechanism with automatic, fine-grained dependency tracking.
---@class heirline.Source
local M = {}

local r = require("heirline.reactive")

--- Shared autocommand group for every reactive source, created on first use so
--- requiring this module has no side effects.
---@type integer?
local augroup = nil

--- Return heirline's reactive autocommand group, creating it if needed.
---@return integer
local function ensure_augroup()
    if not augroup then
        augroup = vim.api.nvim_create_augroup("HeirlineReactive", { clear = true })
    end
    return augroup
end

--- Whether a repaint has already been scheduled for the current event loop
--- iteration; guards `request_redraw` against scheduling redundant redraws.
local redraw_scheduled = false

--- Request a repaint of all heirline-managed lines.
---
--- Calls are coalesced: the first call schedules a single redraw on the main
--- loop and subsequent calls before it runs are ignored. This makes it safe to
--- call from many effects reacting to the same event burst, and safe to call
--- from fast event contexts (the work is deferred via `vim.schedule`).
function M.request_redraw()
    if redraw_scheduled then
        return
    end
    redraw_scheduled = true
    vim.schedule(function()
        redraw_scheduled = false
        -- `redrawstatus!` repaints the statusline and winbar of every window;
        -- the tabline is repainted separately. Both are guarded because they
        -- error while the command line is active.
        pcall(vim.cmd, "redrawstatus!")
        pcall(vim.cmd, "redrawtabline")
    end)
end

---@class heirline.source.AutocmdSpec
---@field events string|string[] event name(s) to listen for; may also be passed positionally as `[1]`
---@field pattern? string|string[] autocommand pattern(s)
---@field get? fun(args: table): any computes the signal's value from the event args; omit for a pulse source
---@field immediate? boolean for value sources, whether to compute an initial value eagerly (default true)
---@field equals? (fun(a: any, b: any): boolean)|false equality policy passed through to the signal
---@field redraw? boolean request a repaint when the event fires (default true)
---@field desc? string autocommand description

--- Create a reactive signal driven by Neovim autocommands.
---
--- Two flavours, selected by whether `spec.get` is provided:
---   * **Value source** (`get` given): the signal holds `get(args)`, recomputed
---     on every matching event. An initial value is computed eagerly unless
---     `immediate = false`.
---   * **Pulse source** (`get` omitted): the signal carries an ever-incrementing
---     tick, so any computation that reads it recomputes whenever an event
---     fires. This mirrors the classic `update = { events }` behaviour for
---     components whose output is read imperatively rather than from a value.
---
--- Writes triggered by an event are wrapped in a `batch` so that, if a single
--- callback updates several pieces of state, dependent effects settle once.
--- After the write, a redraw is requested (coalesced through `request_redraw`)
--- so the lines that read this source repaint; pass `redraw = false` for
--- sources that should not, on their own, trigger a repaint.
---
--- If called while a reactive computation or `root` scope is active, the
--- backing autocommand is deleted when that scope is disposed. The returned
--- `dispose` function deletes it explicitly.
---@param spec heirline.source.AutocmdSpec
---@return fun(): any get, fun() dispose
function M.from_autocmd(spec)
    local events = spec.events or spec[1]
    assert(events, "heirline.source.from_autocmd: `events` is required")

    local compute = spec.get
    local redraw = spec.redraw ~= false
    local get, set, on_event

    if compute then
        local initial = spec.immediate ~= false and compute({}) or nil
        get, set = r.signal(initial, spec.equals ~= nil and { equals = spec.equals } or nil)
        on_event = function(args)
            set(compute(args))
        end
    else
        local tick = 0
        get, set = r.signal(tick)
        on_event = function()
            tick = tick + 1
            set(tick)
        end
    end

    local au_id = vim.api.nvim_create_autocmd(events, {
        group = ensure_augroup(),
        pattern = spec.pattern,
        desc = spec.desc or "heirline reactive autocmd source",
        callback = function(args)
            r.batch(function()
                on_event(args)
            end)
            if redraw then
                M.request_redraw()
            end
        end,
    })

    local disposed = false
    local function dispose()
        if disposed then
            return
        end
        disposed = true
        pcall(vim.api.nvim_del_autocmd, au_id)
    end

    r.on_cleanup(dispose)
    return get, dispose
end

--- Create a pulse signal driven by a `User` autocommand pattern.
---
--- Reading the returned getter inside a computation makes that computation
--- recompute whenever `doautocmd User <pattern>` fires. This is the reactive
--- equivalent of the classic `update = { "User", pattern = <pattern> }`.
---@param pattern string|string[]
---@return fun(): any get, fun() dispose
function M.from_user_event(pattern)
    return M.from_autocmd({ events = "User", pattern = pattern, desc = "heirline reactive User source" })
end

--- Delete heirline's reactive autocommand group and every source registered in
--- it. Individual signals created afterwards lazily recreate the group.
function M.clear()
    if augroup then
        pcall(vim.api.nvim_del_augroup_by_id, augroup)
        augroup = nil
    end
end

return M
