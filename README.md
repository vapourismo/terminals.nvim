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

User window options are merged first. The manager then enforces the behavior it
depends on: `position = "float"`, the configured width, manual folding with
folding disabled, terminal-mode `<Esc>` to leave Terminal mode,
terminal-mode `<S-Esc>` to send a literal escape byte to the job, and no
Normal-mode `q` mapping.

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

See `:help terminals.nvim` for the full help file.
