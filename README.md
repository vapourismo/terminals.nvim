# terminals.nvim

`terminals.nvim` is a small floating terminal manager built around the
persistent window objects provided by
[Snacks Terminal](https://github.com/folke/snacks.nvim/blob/main/docs/terminal.md).
It keeps terminals ordered by creation time, remembers the selected terminal,
and shares that state across tabs.

Terminals are grouped by the effective Neovim working directory returned by
`getcwd()`. The directory is normalized without resolving symbolic links, so
changing Neovim's directory switches to a separate terminal group.

## Requirements

- Neovim with `vim.fs.normalize()` support
- [folke/snacks.nvim](https://github.com/folke/snacks.nvim), with its terminal
  module available

## Installation

With lazy.nvim (replace `OWNER` with the repository owner):

```lua
{
  "OWNER/terminals.nvim",
  dependencies = { "folke/snacks.nvim" },
  opts = {},
}
```

Snacks may be configured normally; `terminals.nvim` calls
`Snacks.terminal.open()` for every newly managed terminal.

## Configuration

Setup is optional. These are the defaults:

```lua
require("terminals").setup({
  width = 220,
  win = {},
})
```

`width` is a character width (Snacks clamps it when the editor is narrower).
`win` accepts additional
[`snacks.win`](https://github.com/folke/snacks.nvim/blob/main/docs/win.md)
float options. Configuration affects terminals created after `setup()`;
existing terminal objects keep their original options.

Every newly created managed terminal has these buffer-local mappings in both
Normal and Terminal modes:

| `win.keys` name | Key | Action |
| --- | --- | --- |
| `term_new` | `<D-n>` | Create a terminal with `require("terminals").new()`. |
| `term_close` | `<D-w>` | Close the focused managed terminal. |
| `term_prev` | `<D-{>` | Select the previous managed terminal. |
| `term_next` | `<D-}>` | Select the next managed terminal. |

The named defaults are merged before user-provided `win.keys`. Replace an
entry by its stable name, or set it to `false` to disable it:

```lua
require("terminals").setup({
  win = {
    keys = {
      term_new = {
        "<leader>tn",
        function()
          require("terminals").new()
        end,
        mode = { "n", "t" },
        desc = "New terminal",
      },
      term_close = false,
    },
  },
})
```

Unrelated custom `win.keys` entries are preserved. The manager applies its
required window behavior last: `position = "float"`, the configured width,
manual folding with folding disabled, and no Normal-mode `q` mapping. Escape
handling uses the Snacks defaults; `terminals.nvim` does not supply Escape
mappings. The enforced window behavior and disabled `q` mapping cannot be
overridden.

## Commands

| Command | Lua | Behavior |
| --- | --- | --- |
| `:TermNew [command...]` | `require("terminals").new(cmd?)` | Create, select, and focus a terminal. Lua accepts a shell string or argv list. |
| `:TermClose` | `.close()` | Destroy the focused managed terminal; do nothing outside one. |
| `:TermPrev` | `.prev()` | Circularly select the previous terminal for the current directory. |
| `:TermNext` | `.next()` | Circularly select the next terminal for the current directory. |
| `:TermToggle` | `.toggle()` | Hide/show the selected terminal, creating a shell terminal for an empty group. |

`TermNew` forwards its command-line arguments as one shell string and provides
shell-command completion. Passing no command creates a terminal using the shell
configured by Snacks.

The Lua functions return the selected Snacks terminal object. `close()`,
`prev()`, and `next()` return `nil` when there is no applicable managed
terminal. `setup()` has no return value.

Only one managed float is shown at a time. Leaving a terminal float hides its
window but preserves its buffer and process; toggling or cycling back restores
the same persistent terminal. Wiping its buffer removes it from the registry.
Intentional closes through `close()`, `:TermClose`, or the default `<D-w>`
mapping are silent. A command that exits unsuccessfully still reports its exit
status and keeps the terminal open for inspection; a successful exit closes it.
When a focused terminal is closed, exits successfully, or is wiped, its
immediate predecessor in creation order is focused. If it has no predecessor,
the immediate successor is focused instead. Removing a background terminal
does not change focus, and removing the group's only terminal leaves focus in
Neovim's remaining window without creating a replacement.

See `:help terminals.nvim` for the full help file.
