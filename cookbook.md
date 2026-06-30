# Cookbook.md

Heirline is a framework for building Neovim status lines on a **fine-grained
reactive system**. You describe each line as a tree of components; heirline
re-renders only the components whose state actually changed, and only repaints
when something does.

## Index

- [Main concepts](#main-concepts)
  - [The reactive model](#the-reactive-model)
  - [Components](#components)
  - [The render context](#the-render-context)
- [The component API](#the-component-api)
  - [`text`](#text)
  - [`group`](#group)
  - [`flexible`](#flexible)
  - [`list`](#list)
  - [`surround`](#surround)
  - [`on_click`](#on_click)
- [Highlights and colors](#highlights-and-colors)
- [Conditions](#conditions)
- [Signals: reacting to the editor](#signals-reacting-to-the-editor)
  - [Built-in signals](#built-in-signals)
  - [Writing your own signal](#writing-your-own-signal)
  - [The reactive primitives](#the-reactive-primitives)
- [Setup](#setup)
- [Recipes](#recipes)
  - [ViMode](#vimode)
  - [FileName and friends](#filename-and-friends)
  - [FileType, encoding and format](#filetype-encoding-and-format)
  - [Ruler and ScrollBar](#ruler-and-scrollbar)
  - [Diagnostics](#diagnostics)
  - [Git](#git)
  - [LSP](#lsp)
  - [Flexible components](#flexible-components-1)
  - [Conditional statuslines](#conditional-statuslines)
  - [Change colors by mode](#change-colors-by-mode)
- [Winbar](#winbar)
- [Statuscolumn](#statuscolumn)
- [Tabline](#tabline)
  - [Buffer line](#buffer-line)
  - [Tab list](#tab-list)
- [Theming](#theming)
- [Performance](#performance)

## Main concepts

### The reactive model

Three primitives, in `heirline.reactive`, underpin everything:

- A **signal** is a piece of state with a getter and a setter. Reading it inside
  a component subscribes that component to it.
- A **memo** is a derived value that recomputes only when something it read
  changes. Every component's render is a memo.
- An **effect** runs a side effect when its dependencies change.

You rarely touch these directly. In practice, **state comes from Neovim events**
through reactive *sources* (`heirline.signal` / `heirline.source`), and your
components read them. When the user changes mode, only the components that read
the mode signal re-render, and the line repaints once.

There is no `update` field and no manual invalidation: dependencies are tracked
automatically as your provider functions run.

### Components

A component is a function `function(ctx) -> getter`. You build them with the
constructors in `heirline.component` and never call them yourself — `setup`
does. The smallest component is a piece of text:

```lua
local c = require("heirline.component")

local Hello = c.text("hello")
```

Components compose into trees with `group`:

```lua
local Statusline = c.group({
    c.text(" left "),
    c.text("%="), -- vim's statusline alignment code, just passed through
    c.text(" right "),
})
```

Pass the root component to `setup`:

```lua
require("heirline").setup({ statusline = Statusline })
```

### The render context

Every component receives a context table, `ctx`. The fields you will use most:

| Field | Meaning |
| --- | --- |
| `ctx.win` | The window the line is being rendered for. |
| `ctx.buf` | The buffer shown in `ctx.win`. |
| `ctx.hl` | A getter for the inherited (already-merged) highlight. |

Always read window/buffer state through `ctx.win` / `ctx.buf` rather than `0` or
"the current window": a component may render for a window that is not focused,
and `ctx` always points at the right one.

Some contexts carry extra fields, documented where relevant: statuscolumn
components get `ctx.lnum()/relnum()/virtnum()`; buffer-list children get
`ctx.bufnr` and `ctx.is_active()/is_visible()`; tab-list children get
`ctx.tabpage` and `ctx.tabnr()/is_active()`.

## The component API

All constructors live in `local c = require("heirline.component")`.

Most accept an `opts` table with these common fields:

| Option | Type | Meaning |
| --- | --- | --- |
| `hl` | table, string, or `fun(ctx)` | The component's highlight, merged over the inherited one. |
| `condition` | `fun(ctx)` | When it returns a falsy value, the component renders nothing. |
| `on_click` | table or function | Make the component clickable (see [`on_click`](#on_click)). |

### `text`

`c.text(provider, opts?)` renders text.

`provider` is a string/number, or a function of the context returning one (or
`nil`/`""` to render nothing).

```lua
-- static
c.text(" NORMAL ")

-- dynamic: re-renders when ctx.buf's name is read and changes
c.text(function(ctx)
    return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ctx.buf), ":t")
end)

-- vim statusline items work too, they are passed straight through
c.text("%P") -- percentage through file
```

### `group`

`c.group(children, opts?)` concatenates child components. Its highlight is
merged over the inherited one and handed down to the children, and it
re-concatenates only when a child's output changes.

```lua
c.group({
    c.text("["),
    c.text(function(ctx) return vim.bo[ctx.buf].filetype end),
    c.text("]"),
}, { hl = { fg = "gray" } })
```

### `flexible`

`c.flexible(priority, options, opts?)` renders the widest of several `options`
(other components, widest first) that fits the available width, narrowing as
space runs out.

```lua
local FileName = c.flexible(1, {
    c.text(function(ctx) return vim.api.nvim_buf_get_name(ctx.buf) end),        -- full path
    c.text(function(ctx) return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ctx.buf), ":~:.") end), -- relative
    c.text(function(ctx) return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ctx.buf), ":t") end),   -- tail only
})
```

`priority` orders contraction across multiple flexible components: the lowest
priority shrinks first. Flexible components may be nested; a nested one with
`priority = nil` derives its priority from its parent and contracts one step
before it.

### `list`

`c.list(spec)` renders a dynamic, keyed list. It is the substrate for the buffer
and tab lists, but is useful on its own.

```lua
c.list({
    items = function() return { "a", "b", "c" } end,  -- read reactively
    render = function(item) return c.text("[" .. item .. "]") end,
    key = function(item) return item end,             -- stable identity (optional)
})
```

- `items` is read reactively; return the current list each time.
- `render(item, index)` returns the component for one item, instantiated in its
  own scope so it can hold per-item reactive state.
- Children are created and disposed as the list changes; one keyed by a stable
  identity keeps its state across reorders.
- `layout(entries, ctx)` optionally composes the ordered entries yourself
  (each `entry` has `.key` and `.get()`), for example to render a subset.

### `surround`

`c.surround(delimiters, color, child)` frames a component with separators tinted
by a shared color (the classic "powerline" wrap). The delimiters take `color` as
foreground; the wrapped component takes it as background.

```lua
c.surround({ "", "" }, "blue", c.text(" status "))
```

`color` may be a value or `fun(ctx)` returning a color (or `nil` for no tint).

### `on_click`

Pass `on_click` in a component's `opts` to make it clickable. It can be a
function, or a table for more control:

```lua
c.text(" click me ", {
    on_click = {
        name = "MyHandler",            -- a stable global name (auto-generated if omitted)
        callback = function(ctx, minwid, nclicks, button, mods)
            print("clicked in window", ctx.win, "with", button)
        end,
    },
})
```

The callback receives the component's context plus Vim's click arguments. Lua
handlers are registered globally and cleaned up automatically when the component
is disposed.

## Highlights and colors

A highlight is a table like `{ fg = ..., bg = ..., bold = true, ... }`. Colors
are 24-bit integers, `"#rrggbb"` strings, color names, or aliases you register.
`hl` may also be a highlight-group name string, or a function of the context.

Highlights **inherit down the tree**: a component merges its own `hl` over the
one it inherits and passes the result to its children. By default the child
wins; set `force = true` on a parent's highlight to override children.

```lua
c.group({
    c.text("X"),                       -- inherits fg = "red"
    c.text("Y", { hl = { fg = "blue" } }), -- overrides to blue
}, { hl = { fg = "red", bold = true } })
```

Register color aliases once and refer to them by name everywhere:

```lua
require("heirline").load_colors({
    bright_bg = "#3b4252",
    green = "#a3be8c",
    git_add = 3,
})

-- or pass them to setup
require("heirline").setup({
    statusline = ...,
    opts = { colors = function() return require("my.colors") end },
})
```

Heirline rebuilds its highlight groups automatically after a `:colorscheme`
change, so dynamic colors stay correct.

## Conditions

`heirline.conditions` provides ready predicates for `opts.condition` (and for
plain use inside providers):

| Function | Returns true when |
| --- | --- |
| `is_active()` | the rendered window is the focused one |
| `is_not_active()` | the rendered window is not focused |
| `buffer_matches(patterns, bufnr?)` | the buffer matches by `filetype`/`buftype`/`bufname` |
| `width_percent_below(n, thresh, is_winbar?)` | `n` is below `thresh` fraction of the width |
| `is_git_repo()` | the buffer is in a git repo (via gitsigns) |
| `has_diagnostics()` | the buffer has diagnostics |
| `lsp_attached()` | an LSP client is attached |

```lua
local Diagnostics = c.group({ ... }, {
    condition = require("heirline.conditions").has_diagnostics,
})

-- special-case some filetypes
local special = function(ctx)
    return require("heirline.conditions").buffer_matches({
        filetype = { "help", "neo-tree", "lazy" },
        buftype = { "terminal", "quickfix" },
    }, ctx.buf)
end
```

`buffer_matches` matches with Lua patterns, so escape magic characters
(`%-`, etc.).

## Signals: reacting to the editor

A component re-renders when a signal it read changes. State that changes with the
editor is exposed as signals you read inside your providers.

### Built-in signals

`heirline.signal` offers ready signals as cached, process-wide getters:

| Accessor | Kind | Read it to… |
| --- | --- | --- |
| `mode()` | value | get the current mode short-name (`n`, `i`, `v`, `niI`, …) |
| `on_cursor_move()` | trigger | re-render when the cursor moves |
| `on_buf_change()` | trigger | re-render when the window's buffer changes/writes |
| `on_win_change()` | trigger | re-render on window focus/layout change |
| `on_diagnostics_change()` | trigger | re-render when diagnostics change |
| `on_lsp_change()` | trigger | re-render on LSP attach/detach |
| `on_tab_change()` | trigger | re-render when tabs are created/closed/switched |
| `on_buflist_change()` | trigger | re-render when buffers are added/removed/entered |
| `is_active(ctx)` | helper | whether `ctx.win` is the focused window |

A **value** signal carries data; call its getter for the value:

```lua
local mode = require("heirline.signal").mode()
c.text(function() return mode():upper() end)
```

A **trigger** carries no useful value; you read it only to subscribe. Read it,
then read the real state you care about:

```lua
local moved = require("heirline.signal").on_cursor_move()
local Ruler = c.text(function(ctx)
    moved() -- subscribe: re-render whenever the cursor moves
    local pos = vim.api.nvim_win_get_cursor(ctx.win)
    return pos[1] .. ":" .. (pos[2] + 1)
end)
```

Cache the getter (`local mode = signal.mode()`) rather than calling the accessor
inside the hot path.

### Writing your own signal

Build a signal from any autocommand with `heirline.source`:

```lua
local source = require("heirline.source")

-- value source: the getter receives the autocommand args (data, buf, ...)
local cwd = source.from_autocmd({
    events = { "DirChanged", "VimEnter" },
    get = function(args) return vim.fn.getcwd() end,
})
c.text(function() return vim.fn.fnamemodify(cwd(), ":t") end)

-- pulse source: no value, just a recompute trigger on a User event
local refresh = source.from_user_event("MyPluginRefresh")
c.text(function() refresh(); return compute_something() end)
```

`from_autocmd` options: `events`, `pattern`, `get`, `immediate` (compute an
initial value, default true — set `false` when `get` needs event args),
`equals`, `redraw` (request a repaint on the event, default true), `desc`.

When a getter relies on the event args, set `immediate = false` (there is no
event at construction time). A pulse source (no `get`) carries the latest event
args as its value, so you can also inspect them.

### The reactive primitives

For advanced cases, `heirline.reactive` exposes the underlying primitives:
`signal`, `memo`, `effect`, `batch`, `untrack`, `on_cleanup`, `root`. For
example, derive a cached value with `memo`:

```lua
local r = require("heirline.reactive")
local moved = require("heirline.signal").on_cursor_move()

local ruler = r.memo(function()
    moved()
    local pos = vim.api.nvim_win_get_cursor(0)
    return pos[1] .. ":" .. (pos[2] + 1)
end)
c.text(function() return ruler() end)
```

## Setup

```lua
require("heirline").setup({
    statusline = ...,    -- a component
    winbar = ...,        -- a component
    tabline = ...,       -- a component
    statuscolumn = ...,  -- a component
    opts = {
        colors = ...,            -- table or function of color aliases
        disable_winbar_cb = ..., -- fun(args) -> boolean: opt a window out of the winbar
    },
})
```

Calling `setup` again replaces the previous configuration, disposing the old
reactive scopes first.

## Recipes

The snippets below assume:

```lua
local c = require("heirline.component")
local signal = require("heirline.signal")
local conditions = require("heirline.conditions")
```

### ViMode

```lua
local mode = signal.mode()

local mode_colors = {
    n = "red", i = "green", v = "cyan", V = "cyan", ["\22"] = "cyan",
    c = "orange", R = "violet", r = "violet", ["!"] = "red", t = "red",
}

local ViMode = c.text(function()
    return " " .. mode():upper() .. " "
end, {
    hl = function()
        -- mode() returns multi-char modes like "niI"; index the first char
        return { fg = mode_colors[mode():sub(1, 1)] or "red", bold = true }
    end,
})
```

The mode signal updates on `ModeChanged`, so `ViMode` re-renders exactly when the
mode changes.

### FileName and friends

```lua
local on_buf = signal.on_buf_change()

local FileName = c.text(function(ctx)
    on_buf()
    local name = vim.api.nvim_buf_get_name(ctx.buf)
    if name == "" then return "[No Name]" end
    return vim.fn.fnamemodify(name, ":t")
end)

local FileFlags = c.group({
    c.text("[+]", { condition = function(ctx) return vim.bo[ctx.buf].modified end }),
    c.text("", { condition = function(ctx)
        return not vim.bo[ctx.buf].modifiable or vim.bo[ctx.buf].readonly
    end }),
})

local FileNameBlock = c.group({ FileName, FileFlags })
```

To shorten the path as space runs out, wrap the name variants in
[`flexible`](#flexible).

### FileType, encoding and format

```lua
local FileType = c.text(function(ctx)
    return string.upper(vim.bo[ctx.buf].filetype)
end)

local FileEncoding = c.text(function(ctx)
    local enc = vim.bo[ctx.buf].fileencoding
    return enc ~= "" and enc:upper() or vim.o.encoding:upper()
end)

local FileFormat = c.text(function(ctx)
    return vim.bo[ctx.buf].fileformat:upper()
end)
```

### Ruler and ScrollBar

```lua
local moved = signal.on_cursor_move()

local Ruler = c.text(function(ctx)
    moved()
    local pos = vim.api.nvim_win_get_cursor(ctx.win)
    return string.format("%d:%d", pos[1], pos[2] + 1)
end)

local bar = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
local ScrollBar = c.text(function(ctx)
    moved()
    local curr = vim.api.nvim_win_get_cursor(ctx.win)[1]
    local total = vim.api.nvim_buf_line_count(ctx.buf)
    local i = math.floor((curr - 1) / total * #bar) + 1
    return string.rep(bar[i] or bar[#bar], 2)
end, { hl = { fg = "blue" } })
```

### Diagnostics

```lua
local changed = signal.on_diagnostics_change()

local function count(ctx, severity)
    return #vim.diagnostic.get(ctx.buf, { severity = vim.diagnostic.severity[severity] })
end

local Diagnostics = c.group({
    c.text(function(ctx) changed(); local n = count(ctx, "ERROR"); return n > 0 and (" E" .. n) or "" end, { hl = { fg = "red" } }),
    c.text(function(ctx) changed(); local n = count(ctx, "WARN");  return n > 0 and (" W" .. n) or "" end, { hl = { fg = "yellow" } }),
}, {
    condition = function(ctx) return #vim.diagnostic.get(ctx.buf) > 0 end,
})
```

The condition itself reads diagnostics, but read the `on_diagnostics_change`
trigger somewhere in the group to be sure the counts refresh on every change.

### Git

```lua
local on_buf = signal.on_buf_change()

local Git = c.group({
    c.text(function(ctx)
        on_buf()
        return " " .. (vim.b[ctx.buf].gitsigns_head or "")
    end),
}, {
    condition = conditions.is_git_repo,
    hl = { fg = "orange" },
})
```

Gitsigns updates `b:gitsigns_status_dict`; trigger re-renders from its event:

```lua
local source = require("heirline.source")
local git = source.from_user_event("GitSignsUpdate")

local GitChanges = c.text(function(ctx)
    git()
    local d = vim.b[ctx.buf].gitsigns_status_dict or {}
    return string.format("+%d ~%d -%d", d.added or 0, d.changed or 0, d.removed or 0)
end)
```

### LSP

```lua
local lsp = signal.on_lsp_change()

local LSPActive = c.text(function(ctx)
    lsp()
    local names = {}
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = ctx.buf })) do
        names[#names + 1] = client.name
    end
    return " [" .. table.concat(names, " ") .. "]"
end, {
    condition = conditions.lsp_attached,
    hl = { fg = "green", bold = true },
})
```

### Flexible components

Put the wide-to-narrow variants of a component into `flexible`, give the line a
few `flexible` islands with different priorities, and heirline fits them to the
window (or to `&columns` under `laststatus=3`):

```lua
local Navic = c.flexible(3, { c.text(long_breadcrumb), c.text(short_breadcrumb), c.text("") })
local WorkDir = c.flexible(1, { c.text(full_cwd), c.text(short_cwd), c.text("") })

local Statusline = c.group({ ViMode, FileNameBlock, Navic, c.text("%="), WorkDir, Ruler })
```

`WorkDir` (priority 1) collapses before `Navic` (priority 3).

### Conditional statuslines

Components hide themselves with `condition`; whole lines can branch the same way.
A common pattern is an active/inactive split and special lines for some buffers:

```lua
local Align = c.text("%=")
local Space = c.text(" ")

local DefaultStatusline = c.group({ ViMode, Space, FileNameBlock, Align, Ruler })

local InactiveStatusline = c.group({
    FileNameBlock, Align,
}, { condition = conditions.is_not_active })

local SpecialStatusline = c.group({
    FileType, Align,
}, {
    condition = function(ctx)
        return conditions.buffer_matches({
            buftype = { "nofile", "prompt", "help", "quickfix" },
            filetype = { "^git.*", "fugitive" },
        }, ctx.buf)
    end,
})

-- first matching branch wins; put the most specific first
local Statusline = c.group({
    SpecialStatusline,
    InactiveStatusline,
    DefaultStatusline,
})
```

Since hidden components render nothing, ordering the branches by specificity (and
giving the fallback no condition) gives you a single line that adapts per window.

### Change colors by mode

Because highlights inherit, set the mode color once on a parent and the children
follow:

```lua
local mode = signal.mode()
local mode_colors = { n = "red", i = "green", v = "cyan", c = "orange", R = "violet", t = "red" }

local Statusline = c.group({
    ViMode, FileNameBlock, c.text("%="), Ruler,
}, {
    hl = function()
        return { bg = mode_colors[mode():sub(1, 1)] or "red", force = true }
    end,
})
```

## Winbar

The winbar is configured the same way and set per eligible window:

```lua
require("heirline").setup({
    winbar = c.group({ FileNameBlock }),
    opts = {
        disable_winbar_cb = function(args)
            return conditions.buffer_matches({
                buftype = { "nofile", "prompt", "help", "quickfix", "terminal" },
            }, args.buf)
        end,
    },
})
```

## Statuscolumn

The statuscolumn is drawn once per screen line, so the line position is reactive
state on the context: read `ctx.lnum()`, `ctx.relnum()`, or `ctx.virtnum()`.
Only the components that read the line number recompute per line.

```lua
local LineNumber = c.text(function(ctx)
    if ctx.virtnum() ~= 0 then return "" end               -- wrapped/virtual line
    if ctx.relnum() == 0 then return ctx.lnum() .. " " end -- current line: absolute
    return ctx.relnum() .. " "                             -- others: relative
end)

require("heirline").setup({
    statuscolumn = c.group({
        c.text("%s"), -- sign column
        LineNumber,
        c.text("%C"), -- fold column
    }),
})
```

## Tabline

`heirline.lists` builds the buffer and tab lists.

### Buffer line

```lua
local lists = require("heirline.lists")

-- a single buffer's component; it reads ctx.bufnr / ctx.is_active() / ctx.is_visible()
local BufferEntry = function(ctx)
    return c.group({
        c.text(function()
            local name = vim.api.nvim_buf_get_name(ctx.bufnr)
            name = name == "" and "[No Name]" or vim.fn.fnamemodify(name, ":t")
            return " " .. name .. " "
        end),
        c.text("● ", { condition = function() return vim.bo[ctx.bufnr].modified end }),
    }, {
        hl = function()
            return ctx.is_active() and { bold = true, fg = "green" } or { fg = "gray" }
        end,
        on_click = {
            name = "heirline_buf_click_" .. ctx.bufnr,
            callback = function() vim.api.nvim_set_current_buf(ctx.bufnr) end,
        },
    })(ctx)
end

local BufferLine = lists.buflist(BufferEntry, {
    left_trunc = "<",  -- shown when buffers precede the visible page (clickable)
    right_trunc = ">", -- shown when buffers follow it (clickable)
})

require("heirline").setup({ tabline = BufferLine })
```

The list pages itself to the available width, always showing the page that
contains the active buffer; the truncation markers move between pages, locking
the page until the next buffer switch. Pass `buffers = function() return {...} end`
to control which buffers appear.

### Tab list

```lua
local lists = require("heirline.lists")

local TabEntry = function(ctx)
    return c.text(function()
        return " " .. ctx.tabnr() .. " "
    end, {
        hl = function()
            return ctx.is_active() and { bold = true } or { fg = "gray" }
        end,
        on_click = {
            name = "heirline_tab_click",
            update = true,
            callback = function(child_ctx)
                vim.api.nvim_set_current_tabpage(child_ctx.tabpage)
            end,
        },
    })(ctx)
end

local TabList = lists.tablist(TabEntry)
```

Combine a buffer line and a tab list with `group` and `%=` to put them on the
same tabline.

## Theming

Define your palette once as aliases and reference them by name; the colors update
when you reload them:

```lua
local function palette()
    local function hl(name, attr) return vim.api.nvim_get_hl(0, { name = name })[attr] end
    return {
        bg = hl("Normal", "bg"),
        red = hl("DiagnosticError", "fg"),
        green = hl("String", "fg"),
        orange = hl("Constant", "fg"),
    }
end

require("heirline").load_colors(palette())

vim.api.nvim_create_autocmd("ColorScheme", {
    callback = function()
        require("heirline").clear_colors()
        require("heirline").load_colors(palette())
    end,
})
```

Heirline rebuilds its highlight groups after a colorscheme change automatically;
the autocommand above keeps your *aliases* current too.

## Performance

The reactive model is the performance story: a redraw recomputes only the
fragments whose signals changed, and clean components are served from cache. Each
window renders in its own scope, so cross-window work is independent.

To benchmark a full (cold) render of each configured line:

```lua
require("heirline").timeit() -- prints average cold-render time per line
```

Real redraws are far cheaper than this worst-case number, since they recompute
only what changed.
