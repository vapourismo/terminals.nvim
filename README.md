# terminals.nvim

`terminals.nvim` is a small terminal manager built around the
persistent window objects provided by
[Snacks Terminal](https://github.com/folke/snacks.nvim/blob/main/docs/terminal.md).
It keeps terminals ordered by creation time and remembers the selected
terminal independently in each tabpage.

Every terminal belongs permanently to the tabpage where it was created.
Terminals are grouped by owner tabpage, the absolute working directory used to
spawn them, and their window position. Each `(tabpage, cwd, position)` group
has its own creation order and selected terminal. Directories are normalized
without resolving symbolic links. Outside a managed terminal, the default
scope uses Neovim's working directory returned by `getcwd()` and the configured
position; inside one, actions inherit the focused terminal's directory and
position.

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
with a manual fold method, and installs its managed winbar expression. Top,
bottom, left, and right terminals receive only the `Normal:NormalFloat` and
`NormalNC:NormalFloat` `winhighlight` mappings, giving focused and inactive
split terminals the same background. Floating terminals do not receive a
`winhighlight` value. Left and right terminals enforce
`winfixwidth = false`. Escape handling uses the Snacks defaults;
`terminals.nvim` does not supply Escape mappings. No global mappings are
installed.

## Commands

| Command | Lua | Behavior |
| --- | --- | --- |
| `:TermNew [command...]` | `require("terminals").new(cmd?, opts?)` | Create and select a terminal. Lua focuses it when its resolved directory matches the applicable directory; otherwise it starts hidden. |
| `:TermClose` | `.close()` | Destroy the focused managed terminal; do nothing outside one. |
| `:TermPrev` | `.prev(opts?)` | Circularly select the previous terminal for the current tab's applicable `(cwd, position)` group. |
| `:TermNext` | `.next(opts?)` | Circularly select the next terminal for the current tab's applicable `(cwd, position)` group. |
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
`setup().position` outside a managed terminal. The resolved creation
position is retained even if `setup()` changes later. Equivalent normalized
paths share creation order and active selection only when their owner tabpages
and positions also match. Tabs never adopt or reuse one another's terminal
objects. `:TermNew` retains its existing command-only syntax; use the Lua API
for custom directories or positions.

When the resolved path matches the captured base directory, `new()` replaces a
visible terminal only at the target position in the current tab and focuses the
new terminal. An explicit different position is therefore opened in the
foreground while edge terminals at other positions and in other tabs remain
visible. When the path differs, the process starts in the background as its
current-tab target group's active selection; the current window and visible
terminals remain in place. Toggling from the target directory in that owner tab
later reveals the same terminal. Because `:TermNew` and the default new-terminal
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
With no position, it considers every managed terminal in the current tab that
currently has a valid window, regardless of cwd or focus. Exactly one visible
terminal is used; zero candidates report an error without creating a terminal,
and multiple candidates require an explicit position. With a position, an
already visible terminal there in the current tab wins even when it belongs to
another cwd. Otherwise `send()` restores the active terminal from the current
tab's applicable `(cwd, position)` group, or creates a shell terminal there
when that group is empty. Visible terminals in other tabs are ignored.

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

At most one managed terminal is shown per position in each tab. Selecting
another terminal hides only the visible terminal at that position in its owner
tab, so edge splits at other positions and all edge windows in other tabs remain
open. Leaving a managed float hides its window while preserving its buffer and
process. This includes switching tabs from a focused float; returning to the
owner tab and toggling restores that tab's persistent object. Edge-positioned
terminals remain visible across focus and tab changes. Wiping a terminal buffer
removes it from its exact `(tabpage, cwd, position)` group.

Closing a tabpage intentionally destroys all terminals it owns, including
hidden, running, failed, or otherwise retained terminals. Their jobs are
terminated and buffers wiped without expected-termination notifications;
terminals owned by other tabs are unaffected.

Every managed terminal has a left-aligned winbar listing only its exact owner
tab, cwd, and position group's terminals in creation order. A non-`nil`
`opts.title`, including an empty string, is authoritative for the terminal's
lifetime. Otherwise, the winbar
uses the terminal's creation command: shell strings are displayed directly,
argv lists are joined with single spaces without shell quoting, and a terminal
created without a command is labeled `terminal`. The selected title uses
`TermBarNameFocused` when its managed terminal window and buffer are current,
and `TermBarNameActive` otherwise, including when an edge terminal remains
visible after focus moves to an editor window. Other titles use `TermBarName`.
Titles remain in creation order, and each has one highlighted padding space on
both sides. A retained terminal that exits with a non-zero status appends its
numeric code directly after its title, with one padding space on both sides
highlighted by `TermBarStatus`. The space between
terminal entries and the remaining winbar use `NormalFloat`. The plugin
consumes `TermBarName`, `TermBarNameActive`, `TermBarNameFocused`,
`TermBarStatus`, `TermBarAttention`, and `NormalFloat` without defining or
overriding them.

An OSC 9 notification issues an INFO notification. Its message may start with
`<title>:` to set the notification title and remove that prefix from the body.
Only the first colon is a separator. Surrounding title whitespace and leading
body whitespace are stripped; additional colons and trailing body whitespace
are preserved. The prefix is recognized only when its trimmed title is
non-empty. Otherwise, the complete message remains the body and the title is
`terminals`. An absent or empty resulting body becomes
`a terminal needs attention`, including when a valid title was provided.

When emitted by an unfocused managed terminal, the notification also adds a
padded `!` box after that terminal's exit-status box, highlighted by
`TermBarAttention`. Repeated notifications retain a single mark. Focusing the
terminal clears it, and notifications emitted while the terminal is focused do
not set the mark. OSC 9;4 progress sequences and unrelated terminal requests
do not issue notifications or set attention.

The plugin also owns the boolean tabpage variable `t:attention` for custom
tablines. It is `true` when at least one valid terminal owned by that tabpage
has unread attention and its cwd matches the tabpage's normalized working
directory, across all terminal positions. It is `false` otherwise.
Tabpage-local `:tcd` directories take precedence over the global directory;
window-local `:lcd` directories are ignored. Tabs that share a directory still
have independent attention state.

Intentional closes through `close()`, `:TermClose`, or the default `<D-w>`
mapping are silent. A command that exits unsuccessfully still reports its exit
status and keeps the terminal open for inspection; a successful exit closes it.
`Ctrl+D` is not remapped: it continues to send EOF to the shell, and when that
ends a focused managed shell successfully it triggers the same adjacent-terminal
handoff. When a focused terminal is closed, exits successfully (including via
`Ctrl+D`), or is wiped, its immediate predecessor in the same owner tab's
`(cwd, position)` group is focused. If it has no predecessor, the immediate
successor from that exact group is focused instead. When a visible but
unfocused edge terminal exits successfully, the same adjacent fallback
replaces it in its owner tab while the previously focused editor or other
window keeps focus. This also works when the owner tab is inactive, without
switching tabs or stealing focus. A hidden
terminal that exits successfully is removed without showing a fallback or
changing focus. A fallback is never selected from another tab, directory, or
position. Removing the group's only terminal closes that position and leaves
focus in Neovim's remaining window without creating a replacement.

`TermSend` and `send()` reject blockwise selections, missing or stale Visual
marks, and unnamed buffers. They also report incompatible filesystem roots, an
invalid or unavailable terminal channel, and channel write failures. Invalid
positions are rejected. Selection and targeting errors do not write any input;
channel errors are reported after the resolved terminal has been focused.

See `:help terminals.nvim` for the full help file.
