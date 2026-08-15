# terminals.nvim

`terminals.nvim` is a small terminal manager built around the
persistent window objects provided by
[Snacks Terminal](https://github.com/folke/snacks.nvim/blob/main/docs/terminal.md).
It keeps terminals ordered by creation time and remembers the selected
terminal independently in each tabpage.

Every terminal belongs permanently to the tabpage where it was created.
Terminals are grouped by owner tabpage, a normalized **group directory**, and
their window position. Each `(tabpage, group directory, position)` group has
its own creation order and selected terminal. The group directory normally
matches the terminal process's working directory, but `new()` can keep the
current group while spawning a process elsewhere. Directories are normalized
without resolving symbolic links. Outside a managed terminal, the default
scope uses Neovim's working directory returned by `getcwd()` and the configured
position; inside one, actions inherit the focused terminal's group directory
and position.

## Requirements

- Neovim with `vim.fs.normalize()` support
- [folke/snacks.nvim](https://github.com/folke/snacks.nvim), with its terminal
  module available

## Installation

With lazy.nvim:

```lua
{
  "vapourismo/terminals.nvim",
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
  position = "float",
})
```

The top-level `position` setting may be `float`, `top`, `bottom`, `left`, or
`right`. The Snacks buffer-replacing `current` position is not part of this
plugin's supported contract. Configuration affects terminals created after
`setup()`; existing terminal objects keep their resolved position. A per-call
`opts.position` takes precedence over a focused managed terminal's position,
which in turn takes precedence over the configured default.

The former `win` configuration field has been removed. This is a breaking API
change: window dimensions, callbacks, window-local options, and key overrides
cannot be supplied through `setup()`. `terminals.nvim` now owns the Snacks
window options it passes, while Snacks provides the initial window dimensions.
Left and right terminal windows remain resizable, and their live widths are
retained independently per tabpage and side after resizing when managed
terminals are created, selected, hidden, or restored.

Every newly created managed terminal has these fixed buffer-local mappings in
both Normal and Terminal modes:

| `win.keys` name | Key | Action |
| --- | --- | --- |
| `term_new` | `<D-n>` | Create a terminal with `require("terminals").new()`. |
| `term_close` | `<D-w>` | Close the focused managed terminal. |
| `term_prev` | `<D-{>` | Select the previous managed terminal. |
| `term_next` | `<D-}>` | Select the next managed terminal. |

These mappings cannot be replaced or disabled through plugin configuration.
The manager also disables the Snacks Normal-mode `q` mapping, disables folding
with a manual fold method, and installs its managed winbar expression. Every
managed terminal position (`float`, `top`, `bottom`, `left`, and `right`)
receives only the `Normal:NormalFloat` and `NormalNC:NormalFloat`
`winhighlight` mappings, giving focused and inactive terminal windows the same
background. Left and right terminals enforce `winfixwidth = false`. Escape
handling uses the Snacks defaults;
`terminals.nvim` does not supply Escape mappings. No global mappings are
installed.

## Commands

| Command | Lua | Behavior |
| --- | --- | --- |
| `:TermNew [command...]` | `require("terminals").new(cmd?, opts?)` | Create and select a terminal. Lua focuses it when its target group directory is the applicable group; otherwise it starts hidden. |
| `:TermClose` | `.close()` | Destroy the focused managed terminal; do nothing outside one. |
| `:TermPrev` | `.prev(opts?)` | Circularly select the previous terminal for the current tab's applicable `(group directory, position)` group. |
| `:TermNext` | `.next(opts?)` | Circularly select the next terminal for the current tab's applicable `(group directory, position)` group. |
| `:TermToggle` | `.toggle(opts?)` | Hide/show the current tab's selected terminal for the applicable group, creating a shell terminal if it is empty. |
| `:'<,'>TermSend [position]` | `.send(opts?)` | Focus a current-tab managed terminal and insert the Visual selection's file location without submitting it. |

`TermNew` forwards its command-line arguments as one shell string and provides
shell-command completion. Passing no command creates a terminal using the shell
configured by Snacks.

`TermSend` is a Visual-mode command with one optional position: `float`, `top`,
`bottom`, `left`, or `right`. For example, select code and run `:TermSend right`.
It captures characterwise or linewise selection marks before terminal focus
changes, focuses the resolved target, and inserts the location through the
terminal buffer's channel. It sends no newline, so the reference remains in the
terminal input for editing.

The Lua API accepts a persistent winbar title, process working directory,
current-group override, position, and per-creation process environment:

```lua
require("terminals").new("npm test", {
  cwd = "../app",
  group = true,
  position = "right",
  title = "Tests",
  env = { NODE_ENV = "test" },
})
```

`opts.cwd` may be absolute or relative. Absolute paths are normalized without
resolving symbolic links. A relative path is resolved against the focused
managed terminal's group directory, or against Neovim's `getcwd()` when invoked
outside a managed terminal. With no `opts.cwd`, `new()` uses that same base
directory. The resolved absolute path is always passed to Snacks as the
process `cwd`.

`opts.group` is a Lua-only boolean. When it is `nil` or `false`, the normalized
process `cwd` is also the new terminal's group directory, preserving the
default cwd-based isolation. When it is `true`, the terminal retains the
applicable current group directory even if its process `cwd` differs. It then
joins that current tabpage and position group's creation order, winbar, active
selection, cycling, toggling, fallback, and attention scope.

`opts.env` is an optional string-to-string table passed to Snacks for the
spawned process. It applies only to that terminal creation. When omitted, it
remains `nil`, preserving the usual Snacks/Neovim environment inheritance.

`opts.position` may select any supported position for that terminal. When it is
omitted, `new()` inherits the focused managed terminal's position, or uses
`setup().position` outside a managed terminal. The resolved creation position
is retained even if `setup()` changes later. Equivalent normalized group
directories share creation order and active selection only when their owner
tabpages and positions also match. Tabs never adopt or reuse one another's
terminal objects. `:TermNew` retains its existing command-only syntax; use the
Lua API for custom directories, grouping, positions, or environments.

When the target group directory matches the captured applicable group,
`new()` replaces a visible terminal only at the target position in the current
tab and focuses the new terminal. Thus `group = true` opens a cross-cwd process
in the foreground and makes it the active entry in the current group. An
explicit different position also opens in the foreground while edge terminals
at other positions and in other tabs remain visible. With `group` omitted or
false, an explicit cwd that differs from the applicable group starts in the
background as its process-cwd group's active selection; the current window and
visible terminals remain in place. Toggling from that target directory in the owner tab
later reveals the same terminal.

Because `:TermNew` and the default new-terminal mapping pass no options, they
use the applicable group directory as both process cwd and group directory and
remain foreground operations. In particular, calling plain `new()` or `<D-n>`
from a `group = true` cross-cwd terminal uses its group directory rather than
inheriting its exceptional process cwd.

`prev()`, `next()`, and `toggle()` accept an optional position target:

```lua
require("terminals").toggle({ position = "left" })
require("terminals").next({ position = "right" })
```

With no target, these functions use the focused managed terminal's position or
the configured default outside one. Their group directory is always the
focused managed terminal's stored group directory or Neovim's current
directory outside one. The argument-free commands use this same implicit
resolution.

`send()` accepts the same optional position shape:

```lua
require("terminals").send({ position = "right" })
```

Call the Lua API while a characterwise or linewise Visual selection is active.
With no position, it considers every managed terminal in the current tab that
currently has a valid window, regardless of group directory, process cwd, or
focus. Exactly one visible terminal is used; zero candidates report an error
without creating a terminal, and multiple candidates require an explicit
position. With a position, an already visible terminal there in the current
tab wins even when it belongs to another group. Otherwise `send()` restores
the active terminal from the current tab's applicable
`(group directory, position)` group, or creates a shell terminal there when
that group is empty. Visible terminals in other tabs are ignored.

The location is relative to the selected terminal's actual process cwd, not
its group directory, and uses 1-based byte columns with inclusive endpoints:

```text
path:line
path:start_line-end_line
path:start_line:start_col-end_line:end_col
```

A characterwise selection that covers complete lines uses the shorter line
form. Reversed selections are normalized. A path outside the terminal's
process cwd may start with `../`.

The Lua functions return the selected Snacks terminal object. `close()`,
`prev()`, and `next()` return `nil` when there is no applicable managed
terminal. A targeted `toggle()` creates a shell terminal when that exact scope
is empty. `send()` returns the focused terminal after a successful channel
write, and `nil` after an error. `setup()` has no return value.

At most one managed terminal is shown per position in each tab. Selecting
another terminal hides only the visible terminal at that position in its owner
tab, so edge splits at other positions and all edge windows in other tabs remain
open. Leaving a managed float hides its window while preserving its buffer and
process. This includes switching tabs from a focused float; returning to the
owner tab and toggling restores that tab's persistent object. Edge-positioned
terminals remain visible across focus and tab changes. Wiping a terminal buffer
removes it from its exact `(tabpage, group directory, position)` group.

Closing a tabpage intentionally destroys all terminals it owns, including
hidden, running, failed, or otherwise retained terminals. Their jobs are
terminated and buffers wiped without expected-termination notifications;
terminals owned by other tabs are unaffected.

Every managed terminal has a left-aligned winbar listing only its exact owner
tab, group directory, and position group's terminals in creation order. A
non-`nil` `opts.title`, including an empty string, is authoritative for the terminal's
lifetime. Otherwise, the winbar
uses the terminal's creation command: shell strings are displayed directly,
argv lists are joined with single spaces without shell quoting, and a terminal
created without a command is labeled `terminal`. The selected title uses
`TermBarNameFocused` when its managed terminal window and buffer are current,
and `TermBarNameActive` otherwise, including when an edge terminal remains
visible after focus moves to an editor window. Other titles use `TermBarName`.
Titles remain in creation order. Title, exit-status, and attention items each
have one highlighted padding space on both sides. The first title's padding
begins at cell 0, with no dedicated base-highlight space before it. A retained
terminal that exits with a non-zero status appends its numeric code after its
title, highlighted by `TermBarStatus`. The one-cell base-highlight separator
before each later terminal entry remains, so all spacing between items is
preserved.
These separators and the trailing full-width winbar fill use `TermBar` when the
rendered managed terminal window and buffer are current, and `TermBarNC`
otherwise. Thus, a visible edge terminal switches its non-item regions to
`TermBarNC` after focus moves to an editor while its selected entry remains
`TermBarNameActive`.
`TermBar`, `TermBarNC`, `TermBarName`, `TermBarNameActive`,
`TermBarNameFocused`, `TermBarStatus`, and `TermBarAttention` are user-defined
highlight groups that the plugin consumes without defining or overriding.
The plugin also consumes `NormalFloat` for managed terminal backgrounds and
the defensive fill rendered for a missing, unmanaged, or stale winbar target.

An OSC 9 notification issues an INFO notification. Its message may start with
`<title>:` to set the notification title and remove that prefix from the body.
Only the first colon is a separator. Surrounding title whitespace and leading
body whitespace are stripped; additional colons and trailing body whitespace
are preserved. The prefix is recognized only when its trimmed title is
non-empty. Otherwise, the complete message remains the body and the title is
`terminals`. An absent or empty resulting body becomes
`a terminal needs attention`, including when a valid title was provided.

When emitted by an unfocused managed terminal, the notification also adds a
padded `!` box after that terminal's title and any exit-status box, highlighted
by `TermBarAttention`. Repeated notifications retain a single mark. Focusing the
terminal clears it. Notifications emitted while the terminal is focused do not
set the mark. OSC 9;4 progress sequences and unrelated terminal requests do not
issue notifications or set attention.

The plugin also owns the boolean tabpage variable `t:attention` for custom
tablines. It is `true` when at least one valid terminal owned by that tabpage
has unread attention and its group directory matches the tabpage's normalized
working directory, across all terminal positions. It is `false` otherwise.
Tabpage-local `:tcd` directories take precedence over the global directory;
window-local `:lcd` directories are ignored. Tabs that share a directory still
have independent attention state.

Intentional closes through `close()`, `:TermClose`, or the default `<D-w>`
mapping are silent. A command that exits unsuccessfully still reports its exit
status and keeps the terminal open for inspection in Normal mode, so ordinary
keypresses do not dismiss it. Restoring the failed terminal or trying to re-enter
Terminal mode keeps it in Normal mode. A successful exit closes the terminal.
`Ctrl+D` is not remapped: it continues to send EOF to the shell, and when that
ends a focused managed shell successfully it triggers the same adjacent-terminal
handoff. When a focused terminal is closed, exits successfully (including via
`Ctrl+D`), or is wiped, its immediate predecessor in the same owner tab's
`(group directory, position)` group is focused. If it has no predecessor, the
immediate successor from that exact group is focused instead. When a visible
but unfocused edge terminal exits successfully, the same adjacent fallback
replaces it in its owner tab while the previously focused editor or other
window keeps focus. This also works when the owner tab is inactive, without
switching tabs or stealing focus. A hidden
terminal that exits successfully is removed without showing a fallback or
changing focus. A fallback is never selected from another tab, group directory,
or position. Removing the group's only terminal closes that position and leaves
focus in Neovim's remaining window without creating a replacement.

`TermSend` and `send()` reject blockwise selections, missing or stale Visual
marks, and unnamed buffers. They also report incompatible filesystem roots, an
invalid or unavailable terminal channel, and channel write failures. Invalid
positions are rejected. Selection and targeting errors do not write any input;
channel errors are reported after the resolved terminal has been focused.

See `:help terminals.nvim` for the full help file.
