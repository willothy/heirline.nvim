<p align="center">
  <h2 align="center">heirline.nvim</h2>
</p>
<p align="center">
  <img src="heirline.png" width="600" >
</p>
<p align="center">The ultimate Neovim Statusline for tinkerers</p>

## About

Heirline.nvim is a no-nonsense Neovim plugin made for rendering statusline/winbar/tabline/statuscolumn format strings.
It is built on a **fine-grained reactive system**: state lives in signals (driven by Neovim events), components are
closures that read them, and a change re-renders only the components that actually depend on it.

Heirline **does not** provide any defaults, in fact, heirline can be
thought of as an API to generate Vim status format strings.

> **Why another statusline plugin?**

Heirline picks up from other popular customizable statusline plugins like
[galaxyline](https://github.com/NTBBloodbath/galaxyline.nvim) and
[feline](https://github.com/feline-nvim/feline.nvim) but removes all the
hard-coded guides and offers you thousands times more freedom. But freedom has a
price: responsibility. I don't get to tell you what your statusline should do.
You're in charge! With Heirline, you have a framework to easily implement
whatever you can imagine, from simple to complex rules!

<p align="center">
  <img width="1578" alt="heirline_prev" src="https://user-images.githubusercontent.com/36300441/187208978-3054fea6-0e3a-432c-a1fc-b4a29da36a7c.png">
</p>

## Features:

- **Fine-grained reactivity**: Components re-render only when a signal they read changes; state comes from Neovim events through reactive sources, with no manual update wiring.
- **Conditionals**: Build custom active/inactive and buftype/filetype/bufname statuslines or single components.
- **Highlight propagation**: Seamlessly surround components within separators and/or set the (dynamic) coloring of a bunch of components at once.
- **Modularity**: Components are plain closures; reuse, nest, and rearrange them freely.
- **Clickable**: Write pure lua callbacks to be executed when clicking a component.
- **Dynamic resizing**: Flexible components adapt to the available width; buffer and tab lists page to fit.
- **Per-window**: Each window renders in its own reactive scope, cached independently.

Heirline is _not_ for everyone, heirline is for people who like tailoring their own tools (and also like lua):

- **No** default statusline is provided
- You **must** write your own statusline

But don't you worry! Along with the inheritance comes [THE FEATUREFUL COOKBOOK](cookbook.md) 📖
of a distant relative. Your dream 🪄 statusline is a
copypaste away!

## Installation

Use your favorite plugin manager

### Packer

```lua
use({
    "rebelot/heirline.nvim",
    -- You can optionally lazy-load heirline on UiEnter
    -- to make sure all required plugins and colorschemes are loaded before setup
    -- event = "UiEnter",
    config = function()
        require("heirline").setup({...})
    end
})
```

## Setup

Each line is a **component**, built with `heirline.component`. A component is a closure that reads signals and
returns its text; group them, give them highlights and conditions, and pass them to `setup`:

```lua
local c = require("heirline.component")
local signal = require("heirline.signal")
local conditions = require("heirline.conditions")

local mode = signal.mode() -- a reactive getter for the current mode

require("heirline").setup({
    statusline = c.group({
        c.text(function() return " " .. mode():upper() .. " " end, { hl = { bold = true } }),
        c.text(" %f "),
        c.text("%="), -- right-align what follows
        c.text(function(ctx)
            return conditions.is_active(ctx) and "active" or "inactive"
        end),
    }),
    -- winbar = ...,
    -- tabline = require("heirline.lists").buflist(my_buffer_component),
    -- statuscolumn = ...,
})
```

Calling `setup` loads your line(s) and wires them to the matching Vim options. The component re-renders by itself
when a signal it read (here, the mode) changes. To learn how to write components, see the [docs](cookbook.md).

### Donate

Buy me coffee and support my work ;)

[![Donate](https://img.shields.io/badge/Donate-PayPal-green.svg)](https://www.paypal.com/donate/?business=VNQPHGW4JEM3S&no_recurring=0&item_name=Buy+me+coffee+and+support+my+work+%3B%29&currency_code=EUR)
