local stub = require("stub_snacks")
_G.Snacks = stub

package.loaded.terminals = nil
local terminals = require("terminals")

local original_cwd = vim.fn.getcwd()
local main_win = vim.api.nvim_get_current_win()
local temp_root = vim.fn.tempname()
vim.fn.mkdir(temp_root, "p")

local tests = 0
local failures = {}

local function fail(message)
  error(message, 2)
end

local function same(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    fail((message or "values differ") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual:   " .. vim.inspect(actual))
  end
end

local function truthy(value, message)
  if not value then
    fail(message or "expected a truthy value")
  end
end

local function falsy(value, message)
  if value then
    fail((message or "expected a falsy value") .. "\nactual: " .. vim.inspect(value))
  end
end

local function test(name, callback)
  tests = tests + 1
  pcall(vim.api.nvim_set_current_win, main_win)
  local ok, err = xpcall(callback, debug.traceback)
  if ok then
    print("ok " .. tests .. " - " .. name)
  else
    failures[#failures + 1] = { name = name, err = err }
    print("not ok " .. tests .. " - " .. name)
  end
end

local function directory(name)
  local path = temp_root .. "/" .. name
  vim.fn.mkdir(path, "p")
  return (vim.uv or vim.loop).fs_realpath(path) or path
end

local function cd(path)
  vim.cmd("cd " .. vim.fn.fnameescape(path))
end

local function current_is(terminal)
  same(vim.api.nvim_get_current_win(), terminal.win, "terminal window should be focused")
  same(vim.api.nvim_get_current_buf(), terminal.buf, "terminal buffer should be focused")
end

local function eventually_current_is(terminal)
  truthy(vim.wait(100, function()
    return vim.api.nvim_get_current_win() == terminal.win
      and vim.api.nvim_get_current_buf() == terminal.buf
  end), "terminal should eventually be focused")
  current_is(terminal)
end

local function set_title(terminal, title)
  vim.api.nvim_buf_set_var(terminal.buf, "term_title", title)
end

local function eval_winbar(terminal, width)
  truthy(terminal:win_valid(), "the terminal winbar requires a valid window")
  local winbar = vim.api.nvim_get_option_value("winbar", { win = terminal.win })
  return vim.api.nvim_eval_statusline(winbar, {
    winid = terminal.win,
    use_winbar = true,
    highlights = true,
    maxwidth = width,
  })
end

local function highlight_spans(result)
  return vim.tbl_map(function(highlight)
    return { group = highlight.group, start = highlight.start }
  end, result.highlights)
end

test("registers commands and forwards command forms", function()
  vim.cmd("runtime plugin/terminals.lua")
  local commands = vim.api.nvim_get_commands({ builtin = false })
  for _, name in ipairs({ "TermNew", "TermClose", "TermPrev", "TermNext", "TermToggle" }) do
    truthy(commands[name], name .. " should be registered")
  end
  same(commands.TermNew.nargs, "*", "TermNew should accept optional arguments")
  same(commands.TermNew.complete, "shellcmd", "TermNew should use shell command completion")

  local before = #stub.opened
  vim.cmd("TermNew")
  same(stub.opened[before + 1].cmd, nil, "empty TermNew should forward nil")

  vim.cmd([[TermNew printf "hello world"]])
  same(stub.opened[before + 2].cmd, [[printf "hello world"]], "TermNew should preserve its raw argument string")

  local argv = { "printf", "%s", "hello world" }
  same(terminals.new(argv).cmd, argv, "the Lua API should preserve argv lists")

  local first_count = stub.opened[before + 1].opts.count
  same(stub.opened[before + 2].opts.count, first_count + 1, "terminal counts should be unique")
  same(stub.opened[before + 3].opts.count, first_count + 2, "terminal counts should increase by creation")
end)

test("silences intentional closes from the API, command, and mapping", function()
  local dir = directory("intentional-close")
  cd(dir)
  local notifications = #stub.notifications

  local api_terminal = terminals.new("api")
  same(api_terminal.opts.auto_close, false, "managed terminals should disable Snacks auto-close")
  same(terminals.close(), api_terminal, "the API should return the intentionally closed terminal")
  falsy(api_terminal:buf_valid(), "the API should destroy the terminal")

  local command_terminal = terminals.new("command")
  vim.cmd("TermClose")
  falsy(command_terminal:buf_valid(), "TermClose should destroy the terminal")

  local mapped_terminal = terminals.new("mapping")
  mapped_terminal.opts.win.keys.term_close[2]()
  falsy(mapped_terminal:buf_valid(), "the close mapping should destroy the terminal")

  same(#stub.notifications, notifications, "intentional closes should not notify")
end)

test("handles spontaneous process exits by status", function()
  local dir = directory("process-exit")
  cd(dir)
  local notifications = #stub.notifications

  local failed = terminals.new("failure")
  local failed_buffer = failed.buf
  failed:exit(17)
  same(#stub.notifications, notifications + 1, "a non-zero exit should notify exactly once")
  same(
    stub.notifications[#stub.notifications],
    "Terminal exited with code 17.\nCheck for any errors.",
    "a non-zero exit should retain the Snacks error message"
  )
  truthy(vim.api.nvim_buf_is_valid(failed_buffer), "a failed terminal should remain available for inspection")
  same(failed.close_count, 0, "a failed terminal should not be closed automatically")
  same(terminals.prev(), failed, "a failed terminal should remain in the registry")
  same(terminals.close(), failed, "a failed terminal should still support intentional close")

  local successful = terminals.new("success")
  local successful_buffer = successful.buf
  successful:exit(0)
  falsy(vim.api.nvim_buf_is_valid(successful_buffer), "a successful terminal should close automatically")
  same(successful.close_count, 1, "a successful terminal should close its Snacks object")
  same(#stub.notifications, notifications + 1, "a zero exit should not notify")
  same(terminals.prev(), nil, "a successful terminal should be removed from the registry")
end)

test("focuses adjacent terminals after intentional closes", function()
  local dir = directory("intentional-focus-handoff")
  cd(dir)

  local first = terminals.new("first")
  local middle = terminals.new("middle")
  local newest = terminals.new("newest")
  same(terminals.prev(), middle, "the middle terminal should be selectable")
  same(terminals.close(), middle, "closing the middle terminal should return it")
  current_is(first)

  same(terminals.close(), first, "closing the first terminal should return it")
  current_is(newest)

  local opened = #stub.opened
  same(terminals.close(), newest, "closing the only terminal should return it")
  same(vim.api.nvim_get_current_win(), main_win, "closing the group should leave focus in Neovim")
  same(#stub.opened, opened, "closing the group should not create a replacement")

  cd(directory("intentional-newest-handoff"))
  local older = terminals.new("older")
  local newer = terminals.new("newer")
  same(terminals.close(), newer, "closing the newest terminal should return it")
  current_is(older)
end)

test("focuses adjacent terminals after successful exits without stealing background focus", function()
  local dir = directory("exit-focus-handoff")
  cd(dir)

  local first = terminals.new("first")
  local middle = terminals.new("middle")
  local newest = terminals.new("newest")
  same(terminals.prev(), middle, "the middle terminal should be selectable")
  middle:exit(0)
  current_is(first)

  first:exit(0)
  current_is(newest)

  vim.api.nvim_set_current_win(main_win)
  cd(directory("background-exit"))
  local fallback = terminals.new("fallback")
  local background = terminals.new("background")
  local focused = terminals.new("focused")
  local background_buffer = background.buf
  falsy(background:win_valid(), "the background terminal should be hidden before it exits")
  background:exit(0)
  falsy(vim.api.nvim_buf_is_valid(background_buffer), "a hidden successful terminal should wipe its buffer")
  same(background.close_count, 1, "a hidden successful terminal should close its Snacks object")
  current_is(focused)
  same(terminals.prev(), fallback, "a hidden successful terminal should be removed from cycling")
  same(terminals.next(), focused, "cycling should skip the exited background terminal")
  current_is(focused)

  vim.api.nvim_set_current_win(main_win)
  vim.wait(20, function()
    return false
  end)
  focused:exit(0)
  same(vim.api.nvim_get_current_win(), main_win, "a hidden terminal exit should not steal editor focus")
  same(terminals.toggle(), fallback, "a background exit should retain the adjacent selection")
  current_is(fallback)
end)

test("retains hidden failed exits for inspection without stealing focus", function()
  cd(directory("background-failed-exit"))
  local notifications = #stub.notifications
  local failed = terminals.new("failed")
  local failed_buffer = failed.buf
  local focused = terminals.new("focused")
  falsy(failed:win_valid(), "the failed terminal should be hidden before it exits")

  failed:exit(17)

  same(#stub.notifications, notifications + 1, "a hidden non-zero exit should notify exactly once")
  same(
    stub.notifications[#stub.notifications],
    "Terminal exited with code 17.\nCheck for any errors.",
    "a hidden non-zero exit should report its status"
  )
  truthy(vim.api.nvim_buf_is_valid(failed_buffer), "a hidden failed terminal should remain inspectable")
  same(failed.close_count, 0, "a hidden failed terminal should remain open")
  current_is(focused)
  same(terminals.prev(), failed, "a hidden failed terminal should remain selectable")
  current_is(failed)
  local rendered = eval_winbar(failed, 24)
  same(
    rendered.str,
    " failed  17   focused " .. string.rep(" ", 2),
    "a hidden failed terminal should display its preserved status when reopened"
  )
end)

test("focuses adjacent terminals after buffer wipes without stealing background focus", function()
  local dir = directory("wipe-focus-handoff")
  cd(dir)

  local first = terminals.new("first")
  local middle = terminals.new("middle")
  local newest = terminals.new("newest")
  same(terminals.prev(), middle, "the middle terminal should be selectable")
  vim.api.nvim_buf_delete(middle.buf, { force = true })
  eventually_current_is(first)

  vim.api.nvim_buf_delete(first.buf, { force = true })
  eventually_current_is(newest)

  local opened = #stub.opened
  vim.api.nvim_buf_delete(newest.buf, { force = true })
  same(vim.api.nvim_get_current_win(), main_win, "wiping the group should leave focus in Neovim")
  same(#stub.opened, opened, "wiping the group should not create a replacement")

  cd(directory("background-wipe"))
  local fallback = terminals.new("fallback")
  local background = terminals.new("background")
  local focused = terminals.new("focused")
  vim.api.nvim_buf_delete(background.buf, { force = true })
  vim.wait(20, function()
    return false
  end)
  current_is(focused)

  vim.api.nvim_set_current_win(main_win)
  vim.wait(20, function()
    return false
  end)
  vim.api.nvim_buf_delete(focused.buf, { force = true })
  vim.wait(20, function()
    return false
  end)
  same(vim.api.nvim_get_current_win(), main_win, "a hidden buffer wipe should not steal editor focus")
  same(terminals.toggle(), fallback, "a background wipe should retain the adjacent selection")
  current_is(fallback)
end)

test("isolates directories and cycles in creation order", function()
  local dir_a = directory("a")
  local dir_b = directory("b")
  local dir_empty = directory("empty")

  cd(dir_a)
  local one = terminals.new("one")
  local two = terminals.new("two")
  local three = terminals.new("three")

  same(terminals.prev(), two, "previous from the newest terminal")
  same(terminals.prev(), one, "previous should follow creation order")
  same(terminals.prev(), three, "previous should wrap")
  same(terminals.next(), one, "next should wrap")
  current_is(one)

  vim.api.nvim_set_current_win(main_win)
  cd(dir_b)
  local other = terminals.new("other")
  same(terminals.prev(), other, "a one-terminal group should cycle to itself")

  vim.api.nvim_set_current_win(main_win)
  cd(dir_a)
  same(terminals.toggle(), one, "directory A should retain its active selection")
  current_is(one)
  same(terminals.toggle(), one, "toggle should return a hidden selection")
  falsy(one:win_valid(), "the second toggle should hide the active terminal")

  cd(dir_empty)
  same(terminals.prev(), nil, "previous should do nothing for an empty group")
  same(terminals.next(), nil, "next should do nothing for an empty group")
  local created = terminals.toggle()
  same(created.cmd, nil, "toggle should create a shell terminal for an empty group")
  current_is(created)
end)

test("starts an absolute cross-directory terminal hidden and reuses it later", function()
  local editor_dir = directory("cwd-absolute-editor")
  local target_dir = directory("cwd-absolute-target")
  cd(editor_dir)

  local requested = target_dir .. "/nested/../."
  local terminal = terminals.new("absolute", { cwd = requested, title = "Absolute" })
  same(terminal.opts.cwd, target_dir, "an absolute cwd should be normalized and forwarded to Snacks")
  truthy(terminal.process_running, "a background-created terminal should be running")
  falsy(terminal:win_valid(), "a cross-directory terminal should be hidden after creation")
  same(vim.api.nvim_get_current_win(), main_win, "cross-directory creation should preserve the editor window")
  same(terminal.opts.win.enter, false, "a background-created Snacks window should not take focus")

  local opened = #stub.opened
  cd(target_dir)
  same(terminals.toggle(), terminal, "toggling from the target directory should reveal the created terminal")
  same(#stub.opened, opened, "revealing a background-created terminal should not create another one")
  current_is(terminal)
  same(
    eval_winbar(terminal, 20).str,
    " Absolute " .. string.rep(" ", 10),
    "cwd and title options should compose"
  )

  local same_group = terminals.new("same-group", { cwd = target_dir .. "/nested/.." })
  same(#stub.opened, opened + 1, "creating another terminal should open exactly one Snacks terminal")
  current_is(same_group)
  same(terminals.prev(), terminal, "the normalized absolute cwd should own the terminal group")
  same(terminals.next(), same_group, "the equivalent absolute cwd should share the group")
end)

test("resolves relative cwd values against the captured applicable directory", function()
  local root = directory("cwd-relative")
  local target = root .. "/target"
  vim.fn.mkdir(target, "p")
  cd(root)
  local normalized_root = vim.fs.normalize(vim.fn.getcwd())
  local normalized_target = vim.fs.normalize(normalized_root .. "/target")

  local equivalent = terminals.new("equivalent", { cwd = "target/.." })
  same(equivalent.opts.cwd, normalized_root, "outside a terminal, relative cwd should use Neovim's cwd")
  current_is(equivalent)

  local cross_relative = terminals.new("cross-relative", { cwd = "target/." })
  same(cross_relative.opts.cwd, normalized_target, "inside a terminal, relative cwd should use its group")
  falsy(cross_relative:win_valid(), "a relative path resolving to another directory should stay hidden")
  current_is(equivalent)

  vim.api.nvim_set_current_win(main_win)
  cd(target)
  same(terminals.toggle(), cross_relative, "the relative target group should retain its background selection")
  local focused_relative = terminals.new("focused-relative", { cwd = "../target/." })
  same(focused_relative.opts.cwd, normalized_target, "a relative equivalent path should use the focused group as its base")
  current_is(focused_relative)
  same(terminals.prev(), cross_relative, "equivalent relative paths should share a group")
end)

test("inherits an overridden cwd for new terminals and the default mapping", function()
  local editor_dir = directory("cwd-inherit-editor")
  local target_dir = directory("cwd-inherit-target")
  cd(editor_dir)
  terminals.setup()

  local first = terminals.new("first", { cwd = target_dir })
  falsy(first:win_valid(), "the overridden terminal should initially be created in the background")
  vim.api.nvim_set_current_win(main_win)
  cd(target_dir)
  same(terminals.toggle(), first, "the overridden terminal should be revealable from its directory")
  local second = terminals.new()
  same(second.opts.cwd, target_dir, "new() should inherit the focused terminal's group")

  first.opts.win.keys.term_new[2]()
  local mapped = stub.opened[#stub.opened]
  same(mapped.opts.cwd, target_dir, "the default new-terminal mapping should inherit the focused group")
  same(terminals.prev(), second, "inherited terminals should remain in creation order")
  same(terminals.prev(), first, "the overridden terminal should share the inherited group")
end)

test("uses a focused overridden group for cycling and toggling", function()
  local editor_dir = directory("cwd-operations-editor")
  local target_dir = directory("cwd-operations-target")
  cd(editor_dir)

  local editor_terminal = terminals.new("editor")
  local editor_hide_count = editor_terminal.hide_count
  local first = terminals.new("first", { cwd = target_dir })
  falsy(first:win_valid(), "cross-directory creation from a terminal should hide only the new terminal")
  truthy(editor_terminal:win_valid(), "cross-directory creation should leave the focused terminal visible")
  same(editor_terminal.hide_count, editor_hide_count, "cross-directory creation should not hide the focused terminal")
  current_is(editor_terminal)

  local second = terminals.new("second", { cwd = target_dir })
  falsy(second:win_valid(), "another terminal for the target group should also start hidden")
  current_is(editor_terminal)

  vim.api.nvim_set_current_win(main_win)
  cd(target_dir)
  same(terminals.toggle(), second, "the overridden group should select its newest background-created terminal")

  same(terminals.prev(), first, "previous should use the focused terminal's overridden group")
  same(terminals.next(), second, "next should use the focused terminal's overridden group")
  same(terminals.toggle(), second, "toggle should hide the focused overridden group's selection")
  falsy(second:win_valid(), "toggle should hide the overridden terminal")

  local opened = #stub.opened
  cd(editor_dir)
  same(terminals.toggle(), editor_terminal, "outside a terminal, toggle should use Neovim's cwd")
  same(#stub.opened, opened, "the editor cwd group should be reused outside a terminal")
  current_is(editor_terminal)
end)

test("renders command-derived winbar titles and ignores buffer titles", function()
  local dir = directory("winbar-render")
  cd(dir)
  terminals.setup()
  vim.api.nvim_set_hl(0, "WinBarName", { fg = "#aaaaaa" })
  vim.api.nvim_set_hl(0, "WinBarNameActive", { fg = "#ffffff" })

  local one = terminals.new("one")
  set_title(one, "ignored")
  local rendered = eval_winbar(one, 20)
  same(rendered.str, " one " .. string.rep(" ", 15), "a string command should remain left aligned")
  same(highlight_spans(rendered), {
    { group = "WinBarNameActive", start = 0 },
    { group = "NormalFloat", start = 5 },
  }, "a single entry and its trailing fill should use the requested highlights")

  local two = terminals.new("two")
  set_title(two, "also ignored")
  rendered = eval_winbar(two, 20)
  same(rendered.str, " one   two " .. string.rep(" ", 9), "entries should retain creation order and exact spacing")
  same(highlight_spans(rendered), {
    { group = "WinBarName", start = 0 },
    { group = "NormalFloat", start = 5 },
    { group = "WinBarNameActive", start = 6 },
    { group = "NormalFloat", start = 11 },
  }, "inactive, separator, active, and trailing regions should be highlighted independently")

  set_title(two, "changed")
  rendered = eval_winbar(two, 20)
  same(rendered.str, " one   two " .. string.rep(" ", 9), "buffer title changes should not affect command labels")

  vim.api.nvim_set_current_win(main_win)
  cd(directory("winbar-literal-command"))
  local literal = terminals.new("100% %#Error#\nready\7")
  rendered = eval_winbar(literal, 48)
  same(
    rendered.str,
    " 100% %#Error# ready  " .. string.rep(" ", 26),
    "command text should render literally with control characters sanitized"
  )
  same(highlight_spans(rendered), {
    { group = "WinBarNameActive", start = 0 },
    { group = "NormalFloat", start = 22 },
  }, "statusline metacharacters in a command should not change highlights")
end)

test("renders failed exit statuses beside active and inactive titles", function()
  cd(directory("winbar-exit-status"))
  terminals.setup()
  vim.api.nvim_set_hl(0, "WinBarName", { fg = "#aaaaaa" })
  vim.api.nvim_set_hl(0, "WinBarNameActive", { fg = "#ffffff" })
  vim.api.nvim_set_hl(0, "TermBarStatus", { fg = "#ff0000" })

  local failed = terminals.new("failed")
  local rendered = eval_winbar(failed, 24)
  same(rendered.str, " failed " .. string.rep(" ", 16), "a running terminal should have no status box")
  same(highlight_spans(rendered), {
    { group = "WinBarNameActive", start = 0 },
    { group = "NormalFloat", start = 8 },
  }, "a running terminal should use only title and fill highlights")

  failed:exit(17)
  rendered = eval_winbar(failed, 24)
  same(rendered.str, " failed  17 " .. string.rep(" ", 12), "a failure should display its exact exit status")
  same(highlight_spans(rendered), {
    { group = "WinBarNameActive", start = 0 },
    { group = "TermBarStatus", start = 8 },
    { group = "NormalFloat", start = 12 },
  }, "the status box should directly follow the active title with padded status highlighting")

  local running = terminals.new("running")
  rendered = eval_winbar(running, 28)
  same(
    rendered.str,
    " failed  17   running " .. string.rep(" ", 6),
    "a failed status should remain visible when its title becomes inactive"
  )
  same(highlight_spans(rendered), {
    { group = "WinBarName", start = 0 },
    { group = "TermBarStatus", start = 8 },
    { group = "NormalFloat", start = 12 },
    { group = "WinBarNameActive", start = 13 },
    { group = "NormalFloat", start = 22 },
  }, "only the separator between terminal entries should use NormalFloat")
end)

test("renders argv and shell terminal winbar titles", function()
  cd(directory("winbar-command-forms"))
  terminals.setup()

  local argv = terminals.new({ "printf", "%s", "hello world" })
  set_title(argv, "ignored")
  local rendered = eval_winbar(argv, 32)
  same(rendered.str, " printf %s hello world " .. string.rep(" ", 9), "argv should be joined with single spaces")
  same(highlight_spans(rendered), {
    { group = "WinBarNameActive", start = 0 },
    { group = "NormalFloat", start = 23 },
  }, "an argv title should retain active and trailing highlights")

  local shell = terminals.new()
  set_title(shell, "ignored")
  rendered = eval_winbar(shell, 44)
  same(
    rendered.str,
    " printf %s hello world   terminal " .. string.rep(" ", 10),
    "a nil command should use the shell terminal placeholder"
  )
  same(highlight_spans(rendered), {
    { group = "WinBarName", start = 0 },
    { group = "NormalFloat", start = 23 },
    { group = "WinBarNameActive", start = 24 },
    { group = "NormalFloat", start = 34 },
  }, "argv and shell terminal entries should preserve independent highlights")
end)

test("uses persistent creation-time titles ahead of command titles", function()
  local dir = directory("winbar-explicit-title")
  cd(dir)
  terminals.setup()

  local named = terminals.new("named", { title = "Named" })
  set_title(named, "dynamic")
  local rendered = eval_winbar(named, 20)
  same(rendered.str, " Named " .. string.rep(" ", 13), "an explicit title should be displayed")

  set_title(named, "changed")
  rendered = eval_winbar(named, 20)
  same(rendered.str, " Named " .. string.rep(" ", 13), "an explicit title should remain authoritative")

  local literal = terminals.new("literal", { title = "100% %#Error#\nready\7" })
  rendered = eval_winbar(literal, 48)
  same(
    rendered.str,
    " Named   100% %#Error# ready  " .. string.rep(" ", 18),
    "explicit titles should render literally with control characters sanitized"
  )
  same(highlight_spans(rendered), {
    { group = "WinBarName", start = 0 },
    { group = "NormalFloat", start = 7 },
    { group = "WinBarNameActive", start = 8 },
    { group = "NormalFloat", start = 30 },
  }, "statusline metacharacters in an explicit title should not change highlights")

  vim.api.nvim_set_current_win(main_win)
  cd(directory("winbar-empty-explicit-title"))
  local empty = terminals.new("empty", { title = "" })
  set_title(empty, "ignored")
  rendered = eval_winbar(empty, 8)
  same(rendered.str, string.rep(" ", 8), "an empty explicit title should not fall back to the command title")
  same(highlight_spans(rendered), {
    { group = "WinBarNameActive", start = 0 },
    { group = "NormalFloat", start = 2 },
  }, "an empty explicit title should retain its padded active region")
end)

test("updates winbar selection while preserving directory isolation", function()
  local dir_a = directory("winbar-a")
  local dir_b = directory("winbar-b")
  cd(dir_a)
  terminals.setup()

  local alpha = terminals.new("alpha")
  set_title(alpha, "alpha")
  local beta = terminals.new("beta")
  set_title(beta, "beta")
  same(terminals.prev(), alpha, "cycling should select the first winbar entry")
  local rendered = eval_winbar(alpha, 24)
  same(rendered.str, " alpha   beta " .. string.rep(" ", 10), "cycling should retain creation order")
  same(highlight_spans(rendered), {
    { group = "WinBarNameActive", start = 0 },
    { group = "NormalFloat", start = 7 },
    { group = "WinBarName", start = 8 },
    { group = "NormalFloat", start = 14 },
  }, "cycling should move the active highlight")

  vim.api.nvim_set_current_win(main_win)
  cd(dir_b)
  local other = terminals.new("other")
  set_title(other, "other")
  rendered = eval_winbar(other, 24)
  same(rendered.str, " other " .. string.rep(" ", 17), "another directory should have an isolated winbar")

  vim.api.nvim_set_current_win(main_win)
  cd(dir_a)
  same(terminals.toggle(), alpha, "the original directory selection should be restored")
  rendered = eval_winbar(alpha, 24)
  same(rendered.str, " alpha   beta " .. string.rep(" ", 10), "restoring a group should not mix directory titles")
end)

test("removes closed, exited, and wiped terminals from the winbar", function()
  local dir = directory("winbar-removal")
  cd(dir)
  terminals.setup()

  local first = terminals.new("first")
  set_title(first, "first")

  local closed = terminals.new("closed")
  set_title(closed, "closed")
  same(terminals.close(), closed, "the newest terminal should close")
  local rendered = eval_winbar(first, 20)
  same(rendered.str, " first " .. string.rep(" ", 13), "a closed terminal should disappear from the winbar")

  local successful = terminals.new("successful")
  set_title(successful, "successful")
  successful:exit(0)
  rendered = eval_winbar(first, 20)
  same(rendered.str, " first " .. string.rep(" ", 13), "a successful exit should disappear from the winbar")

  local wiped = terminals.new("wiped")
  set_title(wiped, "wiped")
  vim.api.nvim_buf_delete(wiped.buf, { force = true })
  eventually_current_is(first)
  rendered = eval_winbar(first, 20)
  same(rendered.str, " first " .. string.rep(" ", 13), "a wiped terminal should disappear from the winbar")
end)

test("shares terminal selections across tabs", function()
  local dir = directory("tabs")
  cd(dir)
  local terminal = terminals.new("shared")
  local opened = #stub.opened

  vim.cmd("tabnew")
  local second_tab_main = vim.api.nvim_get_current_win()
  cd(dir)
  same(terminals.toggle(), terminal, "another tab should reuse the directory selection")
  same(#stub.opened, opened, "reusing a selection should not open a new terminal")
  current_is(terminal)

  vim.api.nvim_set_current_win(second_tab_main)
  vim.wait(50, function()
    return not terminal:win_valid()
  end)
  vim.cmd("tabclose")
end)

test("closes only a focused managed terminal and prunes wiped buffers", function()
  local dir = directory("close")
  cd(dir)
  local managed = terminals.new("managed")
  local close_count = managed.close_count

  vim.api.nvim_set_current_win(main_win)
  same(terminals.close(), nil, "close should do nothing outside a managed float")
  same(managed.close_count, close_count, "outside close should not touch the process")

  same(terminals.toggle(), managed, "toggle should restore the managed terminal")
  same(terminals.close(), managed, "close should return the destroyed terminal")
  same(managed.close_count, close_count + 1, "focused close should destroy the terminal")
  falsy(managed:buf_valid(), "focused close should wipe the terminal buffer")

  local kept = terminals.new("kept")
  local wiped = terminals.new("wiped")
  vim.api.nvim_buf_delete(wiped.buf, { force = true })
  falsy(wiped:buf_valid(), "the test terminal should be wiped")
  same(terminals.prev(), kept, "a wiped terminal should be removed from cycling")
  current_is(kept)
end)

test("hides on WinLeave without terminating and restores later", function()
  local dir = directory("leave")
  cd(dir)
  local terminal = terminals.new("long-running")
  local buffer = terminal.buf
  local opened = #stub.opened
  local hide_count = terminal.hide_count

  vim.api.nvim_set_current_win(main_win)
  vim.wait(100, function()
    return not terminal:win_valid()
  end)
  falsy(terminal:win_valid(), "leaving the float should hide its window")
  truthy(vim.api.nvim_buf_is_valid(buffer), "leaving the float should preserve its buffer")
  same(terminal.close_count, 0, "leaving the float should not close the terminal")
  truthy(terminal.hide_count > hide_count, "WinLeave should invoke hide")

  same(terminals.toggle(), terminal, "toggle should restore the hidden object")
  same(#stub.opened, opened, "restoring should not create a replacement")
  current_is(terminal)
end)

test("provides terminal-scoped action mappings whose callbacks manage terminals", function()
  local dir = directory("default-mappings")
  cd(dir)
  terminals.setup()

  local first = terminals.new("first")
  local keys = first.opts.win.keys
  local expected = {
    term_new = { "<D-n>", "New terminal" },
    term_close = { "<D-w>", "Close terminal" },
    term_prev = { "<D-{>", "Previous terminal" },
    term_next = { "<D-}>", "Next terminal" },
  }
  for name, values in pairs(expected) do
    local mapping = keys[name]
    truthy(mapping, name .. " should be configured through the terminal window")
    same(mapping[1], values[1], name .. " key sequence")
    same(type(mapping[2]), "function", name .. " callback")
    same(mapping.mode, { "n", "t" }, name .. " modes")
    same(mapping.desc, values[2], name .. " description")
  end
  same(keys.term_normal, nil, "Escape handling should use the Snacks default")
  same(keys.term_escape, nil, "the plugin should not add another Escape mapping")

  keys.term_new[2]()
  local second = stub.opened[#stub.opened]
  same(second.cmd, nil, "the new-terminal mapping should create a shell terminal")
  current_is(second)

  keys.term_prev[2]()
  current_is(first)
  keys.term_next[2]()
  current_is(second)

  keys.term_close[2]()
  same(second.close_count, 1, "the close mapping should destroy the focused terminal")
  falsy(second:buf_valid(), "the close mapping should wipe the terminal buffer")
end)

test("merges float options and enforces terminal invariants", function()
  local dir = directory("options")
  cd(dir)
  terminals.setup()
  local existing = terminals.new("defaults")
  same(existing.opts.win.width, 220, "default width")

  local on_win = function() end
  local custom_new = { "N", function() end, mode = "n", desc = "Custom new" }
  local custom_close = { "C", function() end, mode = "t", desc = "Custom close" }
  local custom_prev = { "P", function() end, mode = { "n", "t" }, desc = "Custom previous" }
  local custom_next = { "X", function() end, mode = { "n", "t" }, desc = "Custom next" }
  terminals.setup({
    width = 91,
    win = {
      border = "double",
      height = 0.6,
      position = "bottom",
      on_win = on_win,
      wo = {
        number = true,
        foldenable = true,
        foldmethod = "expr",
        winbar = "user winbar",
      },
      keys = {
        q = "close",
        custom = { "x", "hide", mode = "n" },
        term_new = custom_new,
        term_close = custom_close,
        term_prev = custom_prev,
        term_next = custom_next,
        term_normal = false,
        term_escape = { "E", "hide", mode = "n" },
      },
    },
  })

  local terminal = terminals.new("configured")
  local win = terminal.opts.win
  same(existing.opts.win.width, 220, "setup should not mutate existing terminal options")
  same(win.position, "float", "position should be enforced")
  same(win.width, 91, "configured character width should be enforced")
  same(win.border, "double", "additional window options should survive")
  same(win.height, 0.6, "additional dimensions should survive")
  same(win.on_win, on_win, "callbacks should survive option merging")
  same(win.wo.number, true, "unrelated window-local options should survive")
  same(win.wo.foldenable, false, "folding should be disabled")
  same(win.wo.foldmethod, "manual", "manual fold method should be enforced")
  same(win.wo.winbar, "%!v:lua.require'terminals'._winbar()", "the managed winbar should be enforced")
  truthy(win.keys.custom, "custom key mappings should survive")
  same(win.keys.term_new, custom_new, "the new-terminal mapping should be replaceable by name")
  same(win.keys.term_close, custom_close, "the close mapping should be replaceable by name")
  same(win.keys.term_prev, custom_prev, "the previous mapping should be replaceable by name")
  same(win.keys.term_next, custom_next, "the next mapping should be replaceable by name")
  same(win.keys.q, false, "the Snacks q mapping should be disabled")
  same(win.keys.term_normal, false, "user-provided Escape options should survive")
  same(win.keys.term_escape, { "E", "hide", mode = "n" }, "user-provided named key options should survive")

  terminals.setup({
    win = {
      keys = {
        custom = { "z", "hide", mode = "n" },
        term_new = false,
        term_close = false,
        term_prev = false,
        term_next = false,
        q = "close",
      },
    },
  })
  local disabled = terminals.new("disabled").opts.win.keys
  same(disabled.term_new, false, "the new-terminal mapping should be disableable by name")
  same(disabled.term_close, false, "the close mapping should be disableable by name")
  same(disabled.term_prev, false, "the previous mapping should be disableable by name")
  same(disabled.term_next, false, "the next mapping should be disableable by name")
  truthy(disabled.custom, "disabling defaults should preserve unrelated mappings")
  same(disabled.q, false, "q should remain enforced when action mappings are disabled")
  same(disabled.term_normal, nil, "Escape handling should still use the Snacks default")
  same(disabled.term_escape, nil, "no additional Escape mapping should be supplied")
end)

pcall(vim.api.nvim_set_current_win, main_win)
pcall(cd, original_cwd)
stub.reset()
vim.fn.delete(temp_root, "rf")

if #failures > 0 then
  print("")
  for _, failure in ipairs(failures) do
    print("FAIL: " .. failure.name)
    print(failure.err)
  end
  print(("\n%d of %d tests failed"):format(#failures, tests))
  vim.cmd("cquit 1")
else
  print(("\nAll %d tests passed"):format(tests))
  vim.cmd("qa!")
end
