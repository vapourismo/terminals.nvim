# terminals.nvim

`terminals.nvim` is a small terminal manager built around the
persistent window objects provided by
[Snacks Terminal](https://github.com/folke/snacks.nvim/blob/main/docs/terminal.md).
It keeps terminals ordered by creation time, remembers the selected terminal,
and shares that state across tabs.

Terminals are grouped by the absolute working directory used to spawn them and
their window position. Each `(cwd, position)` group has its own creation order
and selected terminal. Directories are normalized without resolving symbolic
links. Outside a managed terminal, the default scope uses Neovim's working
directory returned by `getcwd()` and the configured position; inside one,
actions inherit the focused terminal's directory and position.

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
  win = {
    position = "float",
  },
})
```

`win` accepts additional
[`snacks.win`](https://github.com/folke/snacks.nvim/blob/main/docs/win.md)
options. `win.position` sets the default position and may be `float`, `top`,
`bottom`, `left`, or `right`. The Snacks buffer-replacing `current` position is
not part of this plugin's supported contract. Configuration affects terminals
created after `setup()`; existing terminal objects keep their resolved position
and other original options. Configure dimensions such as `width` and `height`
inside `win` when needed for the chosen position; otherwise Snacks chooses
them.

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
required window behavior last: the resolved position, manual folding with
folding disabled, its managed `win.wo.winbar` expression, and no Normal-mode
`q` mapping. Top, bottom, left, and right terminals enforce
`win.wo.winhighlight` mappings from both `Normal` and `NormalNC` to
`NormalFloat`, giving focused and inactive split terminals the same background.
Conflicting user mappings for those two groups are replaced, while unrelated
`winhighlight` mappings are preserved; floating terminals leave the option
unchanged. Left and right terminals also enforce `win.wo.winfixwidth = false`,
so a configured `win.width` sets their initial width without preventing later
resizing. Their live width is retained when managed terminals are created,
selected, hidden, or restored. A per-call position takes precedence over
`win.position`. Escape handling uses the Snacks defaults; `terminals.nvim` does
not supply Escape mappings. These enforced window options and the disabled `q`
mapping cannot be overridden; in particular, a user-provided `win.wo.winbar` is
replaced.

## Commands

| Command | Lua | Behavior |
| --- | --- | --- |
| `:TermNew [command...]` | `require("terminals").new(cmd?, opts?)` | Create and select a terminal. Lua focuses it when its resolved directory matches the applicable directory; otherwise it starts hidden. |
| `:TermClose` | `.close()` | Destroy the focused managed terminal; do nothing outside one. |
| `:TermPrev` | `.prev(opts?)` | Circularly select the previous terminal for the applicable `(cwd, position)` group. |
| `:TermNext` | `.next(opts?)` | Circularly select the next terminal for the applicable `(cwd, position)` group. |
| `:TermToggle` | `.toggle(opts?)` | Hide/show the selected terminal for the applicable group, creating a shell terminal if it is empty. |
| `:'<,'>TermSend [position]` | `.send(opts?)` | Focus a managed terminal and insert the Visual selection's file location without submitting it. |

`TermNew` forwards its command-line arguments as one shell string and provides
shell-command completion. Passing no command creates a terminal using the shell
configured by Snacks.

`TermSend` is a Visual-mode command with one optional position: `float`, `top`,
`bottom`, `left`, or `right`. For example, select code and run `:TermSend right`.
It captures characterwise or linewise selection marks before terminal focus
changes, focuses the resolved target, and inserts the location through the
terminal buffer's channel. It sends no newline, so the reference remains in the
terminal input for editing.

The Lua API accepts a persistent winbar title, working directory, and position
at creation time:

```lua
require("terminals").new("npm test", {
  cwd = "../app",
  position = "right",
  title = "Tests",
})
```

`opts.cwd` may be absolute or relative. Absolute paths are normalized without
resolving symbolic links. A relative path is resolved against the focused
managed terminal's group, or against Neovim's `getcwd()` when invoked outside a
managed terminal. With no `opts.cwd`, `new()` uses that same base directory.
The resolved absolute path is passed to Snacks as the process `cwd` and owns the
terminal's directory scope.

`opts.position` may select any supported position for that terminal. When it is
omitted, `new()` inherits the focused managed terminal's position, or uses
`setup().win.position` outside a managed terminal. The resolved creation
position is retained even if `setup()` changes later. Equivalent normalized
paths share creation order and active selection only when their positions also
match. `:TermNew` retains its existing command-only syntax; use the Lua API for
custom directories or positions.

When the resolved path matches the captured base directory, `new()` replaces a
visible terminal only at the target position and focuses the new terminal. An
explicit different position is therefore opened in the foreground while edge
terminals at other positions remain visible. When the path differs, the process
starts in the background as its target group's active selection; the current
window and visible terminals remain in place. Toggling from the target directory
later reveals that same terminal. Because `:TermNew` and the default new-terminal
mapping set neither directory nor position, they inherit both from a focused
managed terminal and remain foreground operations.

`prev()`, `next()`, and `toggle()` accept an optional position target:

```lua
require("terminals").toggle({ position = "left" })
require("terminals").next({ position = "right" })
```

With no target, these functions use the focused managed terminal's position or
the configured default outside one. Their directory is always the focused
managed terminal's directory or Neovim's current directory outside one. The
argument-free commands use this same implicit resolution.

`send()` accepts the same optional position shape:

```lua
require("terminals").send({ position = "right" })
```

Call the Lua API while a characterwise or linewise Visual selection is active.
With no position, it considers every managed terminal that currently has a
valid window, regardless of cwd or focus. Exactly one visible terminal is used;
zero candidates report an error without creating a terminal, and multiple
candidates require an explicit position. With a position, an already visible
terminal there wins even when it belongs to another cwd. Otherwise `send()`
restores the active terminal from the applicable `(cwd, position)` group, or
creates a shell terminal when that group is empty.

The location is relative to the selected terminal's cwd and uses 1-based byte
columns with inclusive endpoints:

```text
path:line
path:start_line-end_line
path:start_line:start_col-end_line:end_col
```

A characterwise selection that covers complete lines uses the shorter line
form. Reversed selections are normalized. A path outside the terminal cwd may
start with `../`.

The Lua functions return the selected Snacks terminal object. `close()`,
`prev()`, and `next()` return `nil` when there is no applicable managed
terminal. A targeted `toggle()` creates a shell terminal when that exact scope
is empty. `send()` returns the focused terminal after a successful channel
write, and `nil` after an error. `setup()` has no return value.

At most one managed terminal is shown per position. Selecting another terminal
hides only the visible terminal at that position, so edge splits at other
positions remain open. Leaving a managed float hides its window while preserving
its buffer and process; edge-positioned terminals remain visible when focus
moves elsewhere. Toggling or cycling restores the same persistent object.
Wiping a terminal buffer removes it from its exact `(cwd, position)` group.

Every managed terminal has a left-aligned winbar listing only its exact group's
terminals in creation order. A non-`nil` `opts.title`, including an empty
string, is authoritative for the terminal's lifetime. Otherwise, the winbar
uses the terminal's creation command: shell strings are displayed directly,
argv lists are joined with single spaces without shell quoting, and a terminal
created without a command is labeled `terminal`. The selected title uses
`WinBarNameActive`; other titles use `WinBarName`. Each title has one
highlighted padding space on both sides. A retained terminal that exits with a
non-zero status appends its numeric code directly after its title, with one
padding space on both sides highlighted by `TermBarStatus`. The space between
terminal entries and the remaining winbar use `NormalFloat`. The plugin
consumes `WinBarName`, `WinBarNameActive`, `TermBarStatus`, `TermBarAttention`,
and `NormalFloat` without defining or overriding them.

An OSC 9 notification emitted by an unfocused managed terminal adds a padded
`!` box after that terminal's exit-status box, highlighted by
`TermBarAttention`. Repeated notifications retain a single mark. Focusing the
terminal clears it, and notifications emitted while the terminal is focused
are ignored. OSC 9;4 progress sequences and unrelated terminal requests do not
set the mark. Notification text is not retained.

The plugin also owns the boolean tabpage variable `t:attention` for custom
tablines. It is `true` when at least one valid managed terminal for the
tabpage's normalized working directory has unread attention, across all
terminal positions, and `false` otherwise. Tabpage-local `:tcd` directories
take precedence over the global directory; window-local `:lcd` directories are
ignored. Tabs that share a directory share its aggregate attention state.

Intentional closes through `close()`, `:TermClose`, or the default `<D-w>`
mapping are silent. A command that exits unsuccessfully still reports its exit
status and keeps the terminal open for inspection; a successful exit closes it.
When a focused terminal is closed, exits successfully, or is wiped, its
immediate predecessor in the same `(cwd, position)` group is focused. If it has
no predecessor, the immediate successor from that exact group is focused
instead. A fallback is never selected from another directory or position.
Removing a background terminal does not change focus, and removing the group's
only terminal leaves focus in Neovim's remaining window without creating a
replacement.

`TermSend` and `send()` reject blockwise selections, missing or stale Visual
marks, and unnamed buffers. They also report incompatible filesystem roots, an
invalid or unavailable terminal channel, and channel write failures. Invalid
positions are rejected. Selection and targeting errors do not write any input;
channel errors are reported after the resolved terminal has been focused.

See `:help terminals.nvim` for the full help file.
