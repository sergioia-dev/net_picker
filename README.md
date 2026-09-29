# net_picker.nvim

Pick a listening process (or a container exposing ports) and act on it: kill,
signal, tail its log, restart, debug, yank its info, or jump to the source file
named in its cmdline.

Two interchangeable backends are bundled, so you only need whichever picker you
already run:

| Backend     | Requires                      |
| ----------- | ----------------------------- |
| `telescope` | `telescope.nvim`, `plenary.nvim` |
| `fzf`       | `fzf-lua`                     |

Container support is optional and works with podman or docker, over the REST
socket. Without a reachable socket the picker falls back to scanning `/proc`.

## Install

With `lazy.nvim`, picking the fzf-lua backend:

```lua
{
  "sergioia-dev/net-picker.nvim",
  dependencies = { "ibhagwan/fzf-lua" }, -- or "nvim-telescope/telescope.nvim"
  config = function()
    require("net_picker").setup({ telescope = false, fzf = true })
  end,
  keys = { { "<leader>nf", function() require("net_picker").net_picker() end, desc = "Net picker" } },
}
```

## Setup

```lua
require("net_picker").setup({ telescope = true, fzf = false }) -- default
require("net_picker").setup({ telescope = false, fzf = true })
```

Exactly one backend is used. Defaults are `telescope = true`, `fzf = false`.
When both are `true`, the `fzf` backend wins.

Calling `setup()` is optional — without it the Telescope backend is used — but
the chosen backend's dependencies must be installed. `setup()` returns the
module, so it chains:

```lua
require("net_picker").setup({ fzf = true }).net_picker()
```

To bypass the selection entirely you can also require a backend directly:

```lua
require("net_picker.telescope").net_picker()
require("net_picker.fzf").net_picker()
```

## Usage

```lua
require("net_picker").net_picker()
```

## Keymaps

| Key   | Action                                                       |
| ----- | ------------------------------------------------------------ |
| `Tab` | multi-select (deduped by PID)                                 |
| `Enter` / `C-k` | kill (SIGTERM + confirm)                            |
| `C-s` | signal submenu (TERM/KILL/HUP/INT/USR1/USR2/STOP/CONT)        |
| `C-t` | tail log in a persistent split (`C-g` greps inside it)        |
| `C-r` | restart (kill + relaunch cmdline in a terminal)               |
| `C-d` | debugger submenu (gdb/strace/py-spy/lsof/cat cmdline)         |
| `C-o` | cd to the process's cwd                                       |
| `C-y` | yank submenu (kill cmd / JSON / markdown / full info)         |
| `C-g` | jump to the source file named in the cmdline                  |

## Layout

```
lua/net_picker/init.lua       -- setup() and backend dispatch
lua/net_picker/telescope.lua  -- telescope.nvim backend
lua/net_picker/fzf.lua        -- fzf-lua backend
```
