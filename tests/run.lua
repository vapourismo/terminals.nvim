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

local function tab_attention(tabpage)
  return vim.api.nvim_tabpage_get_var(tabpage or vim.api.nvim_get_current_tabpage(), "attention")
end

local function highlight_spans(result)
  return vim.tbl_map(function(highlight)
    return { group = highlight.group, start = highlight.start }
  end, result.highlights)
end

local function source_buffer(dir, name, lines)
  local path = dir .. "/" .. name
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, path)
  vim.api.nvim_buf_set_lines(buf, 0, -1, true, lines)
  vim.api.nvim_win_set_buf(main_win, buf)
  return buf, path
end

local function select_visual(buf, mode, start_line, start_col, end_line, end_col)
  vim.api.nvim_set_current_win(main_win)
  vim.api.nvim_win_set_buf(main_win, buf)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  vim.api.nvim_win_set_cursor(main_win, { start_line, start_col - 1 })
  vim.cmd.normal({ args = { mode }, bang = true })
  vim.api.nvim_win_set_cursor(main_win, { end_line, end_col - 1 })
  same(vim.fn.mode(1), mode, "the test selection should remain active")
end

local function with_cleanup(callback, cleanup)
  local ok, err = xpcall(callback, debug.traceback)
  local cleanup_ok, cleanup_err = pcall(cleanup)
  if not ok then
    error(err, 0)
  end
  if not cleanup_ok then
    error(cleanup_err, 0)
  end
end

local function with_channel_mocks(channels, callback, send_impl)
  local get_option_value = vim.api.nvim_get_option_value
  local chan_send = vim.api.nvim_chan_send
  local sent = {}
  vim.api.nvim_get_option_value = function(name, opts)
    if name == "channel" and opts and opts.buf then
      return channels[opts.buf]
    end
    return get_option_value(name, opts)
  end
  vim.api.nvim_chan_send = send_impl or function(channel, data)
    sent[#sent + 1] = { channel = channel, data = data }
  end

  local ok, err = xpcall(function()
    callback(sent)
  end, debug.traceback)
  vim.api.nvim_get_option_value = get_option_value
  vim.api.nvim_chan_send = chan_send
  if not ok then
    error(err, 0)
  end
end

test("registers commands and forwards command forms", function()
  vim.cmd("runtime plugin/terminals.lua")
  local commands = vim.api.nvim_get_commands({ builtin = false })
  for _, name in ipairs({ "TermNew", "TermClose", "TermPrev", "TermNext", "TermToggle", "TermSend" }) do
    truthy(commands[name], name .. " should be registered")
  end
  same(commands.TermNew.nargs, "*", "TermNew should accept optional arguments")
  same(commands.TermNew.complete, "shellcmd", "TermNew should use shell command completion")
  same(commands.TermSend.nargs, "?", "TermSend should accept an optional position")
  same(commands.TermSend.range, ".", "TermSend should accept a Visual range")
  for _, name in ipairs({ "TermClose", "TermPrev", "TermNext", "TermToggle" }) do
    same(commands[name].nargs, "0", name .. " should reject arguments")
  end
  same(
    vim.fn.getcompletion("TermSend ", "cmdline"),
    { "float", "top", "bottom", "left", "right" },
    "TermSend should complete supported positions"
  )
  same(vim.fn.getcompletion("TermSend r", "cmdline"), { "right" }, "TermSend should filter completion by prefix")
  same(vim.fn.getcompletion("TermSend x", "cmdline"), {}, "TermSend should reject unknown completion prefixes")

  local command_calls = {}
  local command_methods = { "close", "prev", "next", "toggle" }
  local originals = {}
  for _, method in ipairs(command_methods) do
    originals[method] = terminals[method]
    terminals[method] = function(...)
      command_calls[#command_calls + 1] = { method = method, argc = select("#", ...) }
    end
  end
  with_cleanup(function()
    vim.cmd("TermClose")
    vim.cmd("TermPrev")
    vim.cmd("TermNext")
    vim.cmd("TermToggle")
  end, function()
    for _, method in ipairs(command_methods) do
      terminals[method] = originals[method]
    end
  end)
  same(command_calls, {
    { method = "close", argc = 0 },
    { method = "prev", argc = 0 },
    { method = "next", argc = 0 },
    { method = "toggle", argc = 0 },
  }, "argument-free commands should dispatch to their matching Lua APIs")

  local send_calls = {}
  local send = terminals.send
  terminals.send = function(options)
    send_calls[#send_calls + 1] = options
  end
  vim.cmd("1,1TermSend")
  vim.cmd("1,1TermSend left")
  terminals.send = send
  same(send_calls[1].position, nil, "empty TermSend should forward no position")
  same(send_calls[1]._command.range, 2, "TermSend should forward its command range")
  same(send_calls[2].position, "left", "TermSend should forward an explicit position")

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

test("formats Visual locations with line and byte-column ranges", function()
  local dir = directory("send-formatting")
  cd(dir)
  terminals.setup()
  local terminal = terminals.new("target", { position = "left" })
  local buf = source_buffer(dir, "source.lua", { "alpha", "bravo xyz", "aé中z", "last" })

  with_channel_mocks({ [terminal.buf] = 101 }, function(sent)
    local cases = {
      { "V", 2, 1, 2, 1, "source.lua:2" },
      { "V", 1, 1, 3, 1, "source.lua:1-3" },
      { "v", 2, 2, 2, 5, "source.lua:2:2-2:5" },
      { "v", 2, 5, 2, 2, "source.lua:2:2-2:5" },
      { "v", 3, 2, 3, 4, "source.lua:3:2-3:4" },
      { "v", 1, 1, 1, 5, "source.lua:1" },
      { "v", 1, 2, 2, 5, "source.lua:1:2-2:5" },
      { "v", 1, 1, 2, 9, "source.lua:1-2" },
    }
    for index, case in ipairs(cases) do
      select_visual(buf, case[1], case[2], case[3], case[4], case[5])
      same(terminals.send({ position = "left" }), terminal, "a formatted reference should return its target")
      same(sent[index], { channel = 101, data = case[6] }, "formatted Visual reference " .. index)
      current_is(terminal)
    end

    select_visual(buf, "v", 4, 1, 4, 1)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    vim.fn.setpos("'<", { 0, 4, 1, 0 })
    vim.fn.setpos("'>", { 0, 4, vim.v.maxcol, 0 })
    same(
      terminals.send({ position = "left", _command = { range = 2, line1 = 4, line2 = 4 } }),
      terminal,
      "a max-column command mark should resolve to the line end"
    )
    same(sent[#sent], { channel = 101, data = "source.lua:4" }, "max-column marks should use the short line form")
  end)
  terminal:hide()
end)

test("captures the command Visual range before focusing its target", function()
  local dir = directory("send-command")
  cd(dir)
  local terminal = terminals.new("target", { position = "right" })
  local buf = source_buffer(dir, "command.lua", { "abcdef", "second" })
  select_visual(buf, "v", 1, 2, 2, 3)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)

  with_channel_mocks({ [terminal.buf] = 102 }, function(sent)
    vim.cmd("'<,'>TermSend right")
    same(sent, {
      { channel = 102, data = "command.lua:1:2-2:3" },
    }, "the command should retain characterwise columns after leaving Visual mode")
    current_is(terminal)
  end)
  terminal:hide()
end)

test("targets visible, hidden, and empty position groups for delivery", function()
  local terminal_dir = directory("send-target-terminal")
  local source_dir = directory("send-target-source")
  cd(terminal_dir)
  local other_cwd = terminals.new("other-cwd", { position = "left" })
  cd(source_dir)
  local buf = source_buffer(source_dir, "target.lua", { "one", "two" })

  with_channel_mocks(setmetatable({ [other_cwd.buf] = 201 }, { __index = function()
    return 299
  end }), function(sent)
    select_visual(buf, "V", 1, 1, 1, 1)
    same(terminals.send(), other_cwd, "one visible terminal should be the default target across cwd scopes")
    same(sent[1], { channel = 201, data = "../send-target-source/target.lua:1" }, "the path should be relative to the target terminal cwd")
    current_is(other_cwd)

    other_cwd:hide()
    local opened = #stub.opened
    select_visual(buf, "V", 1, 1, 1, 1)
    same(terminals.send(), nil, "no visible default target should fail")
    same(#stub.opened, opened, "default delivery should not create a terminal")
    same(stub.notifications[#stub.notifications], "No open managed terminal exists; specify a position to open one.", "the missing default target should notify")

    local left = terminals.new("left", { position = "left" })
    local right = terminals.new("right", { position = "right" })
    select_visual(buf, "V", 1, 1, 2, 1)
    same(terminals.send(), nil, "multiple visible positions should be ambiguous")
    same(stub.notifications[#stub.notifications], "Multiple open managed terminals exist; specify a position.", "ambiguity should notify")
    same(vim.api.nvim_get_current_win(), main_win, "ambiguous delivery should not move focus")

    select_visual(buf, "v", 1, 2, 1, 2)
    same(terminals.send({ position = "right" }), right, "an explicit position should select among visible terminals")
    same(sent[#sent], { channel = 299, data = "target.lua:1:2-1:2" }, "explicit visible delivery payload")
    current_is(right)

    left:hide()
    right:hide()
    opened = #stub.opened
    select_visual(buf, "V", 2, 1, 2, 1)
    same(terminals.send({ position = "left" }), left, "an explicit position should reopen its hidden active terminal")
    same(#stub.opened, opened, "reopening a hidden group should not create a terminal")
    current_is(left)

    left:hide()
    opened = #stub.opened
    select_visual(buf, "V", 2, 1, 2, 1)
    local created = terminals.send({ position = "top" })
    same(created, stub.opened[#stub.opened], "an empty explicit position should return its created terminal")
    same(#stub.opened, opened + 1, "an empty explicit position should create one terminal")
    same(created.cmd, nil, "an empty group should create a shell terminal")
    same(created.opts.cwd, source_dir, "the created target should use the applicable cwd")
    same(created.opts.win.position, "top", "the created target should use the requested position")
    same(sent[#sent], { channel = 299, data = "target.lua:2" }, "created terminal delivery payload")
    current_is(created)
    created:hide()
  end)
end)

test("makes a visible TermSend target the active terminal", function()
  local terminal_dir = directory("send-visible-active-terminal")
  local source_dir = directory("send-visible-active-source")
  cd(terminal_dir)
  terminals.setup()

  vim.api.nvim_set_hl(0, "WinBarName", { fg = "#aaaaaa" })
  vim.api.nvim_set_hl(0, "WinBarNameActive", { fg = "#ffffff" })
  local visible = terminals.new("visible", { position = "top" })
  vim.api.nvim_set_current_win(main_win)
  cd(source_dir)
  local background = terminals.new("background", { cwd = terminal_dir, position = "top" })
  falsy(background:win_valid(), "the newer cross-directory terminal should start hidden")
  truthy(visible:win_valid(), "background creation should leave the older terminal visible")

  local buf = source_buffer(source_dir, "active.lua", { "selected" })
  with_channel_mocks({ [visible.buf] = 250 }, function(sent)
    select_visual(buf, "V", 1, 1, 1, 1)
    same(terminals.send({ position = "top" }), visible, "the visible terminal should win explicit targeting")
    same(sent, {
      { channel = 250, data = "../send-visible-active-source/active.lua:1" },
    }, "the visible target should receive the selection")
    current_is(visible)
  end)

  local rendered = eval_winbar(visible, 28)
  same(rendered.str, " visible   background " .. string.rep(" ", 6), "the focused send target should be selected")
  same(highlight_spans(rendered), {
    { group = "WinBarNameActive", start = 0 },
    { group = "NormalFloat", start = 9 },
    { group = "WinBarName", start = 10 },
    { group = "NormalFloat", start = 22 },
  }, "TermSend should move the active winbar highlight to its visible target")
  same(terminals.next(), background, "cycling should continue from the visible send target")
  current_is(background)
  background:hide()
end)

test("rejects non-Visual, stale, and malformed command selections", function()
  local dir = directory("send-command-errors")
  cd(dir)
  local terminal = terminals.new("target", { position = "bottom" })
  local buf = source_buffer(dir, "command-errors.lua", { "alpha", "beta" })
  local focus_count = terminal.focus_count
  local opened = #stub.opened

  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  vim.cmd("TermSend bottom")
  same(stub.notifications[#stub.notifications], "TermSend must be called from Visual mode.", "a command without a Visual range should notify")

  same(terminals.send({ position = "bottom" }), nil, "the Lua API should reject Normal mode")
  same(
    stub.notifications[#stub.notifications],
    "A characterwise or linewise Visual selection is required.",
    "the Lua API should explain its required selection mode"
  )

  select_visual(buf, "v", 1, 1, 1, 2)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  vim.cmd("2,2TermSend bottom")
  same(stub.notifications[#stub.notifications], "TermSend must be called from Visual mode.", "a stale command range should notify")

  select_visual(buf, "v", 1, 1, 1, 1)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  vim.fn.setpos("'<", { 0, 1, 1, 0 })
  vim.fn.setpos("'>", { 0, 1, 99, 0 })
  same(
    terminals.send({ position = "bottom", _command = { range = 2, line1 = 1, line2 = 1 } }),
    nil,
    "a command endpoint beyond the line should fail"
  )
  same(stub.notifications[#stub.notifications], "Visual selection is missing or invalid.", "a malformed endpoint should notify")

  same(terminal.focus_count, focus_count, "selection validation failures should not focus a target")
  same(vim.api.nvim_get_current_win(), main_win, "selection validation failures should preserve editor focus")
  same(#stub.opened, opened, "selection validation failures should not create terminals")
  terminal:hide()
end)

test("rejects invalid selections and reports channel delivery failures", function()
  local dir = directory("send-errors")
  cd(dir)
  local terminal = terminals.new("target", { position = "bottom" })
  local buf = source_buffer(dir, "errors.lua", { "alpha", "beta" })

  select_visual(buf, "v", 1, 1, 1, 2)
  same(terminals.send({ position = "diagonal" }), nil, "an unsupported position should fail")
  same(stub.notifications[#stub.notifications], "Invalid terminal position: diagonal.", "an invalid position should notify")

  local unnamed = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(unnamed, 0, -1, true, { "unnamed" })
  select_visual(unnamed, "v", 1, 1, 1, 2)
  same(terminals.send({ position = "bottom" }), nil, "an unnamed selection should fail")
  same(stub.notifications[#stub.notifications], "Visual selection must be in a named buffer.", "an unnamed buffer should notify")

  select_visual(buf, "\22", 1, 1, 2, 2)
  same(terminals.send({ position = "bottom" }), nil, "a blockwise selection should fail")
  same(stub.notifications[#stub.notifications], "Blockwise Visual selections are not supported.", "a blockwise selection should notify")

  select_visual(buf, "v", 1, 1, 1, 2)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  vim.fn.setpos("'<", { 0, 0, 0, 0 })
  vim.fn.setpos("'>", { 0, 0, 0, 0 })
  same(terminals.send({ position = "bottom", _command = { range = 2, line1 = 0, line2 = 0 } }), nil, "invalid Visual marks should fail")
  same(stub.notifications[#stub.notifications], "Visual selection is missing or invalid.", "invalid marks should notify")

  select_visual(buf, "V", 1, 1, 1, 1)
  with_channel_mocks({ [terminal.buf] = 0 }, function()
    same(terminals.send({ position = "bottom" }), nil, "an invalid terminal channel should fail")
    same(stub.notifications[#stub.notifications], "Managed terminal has no valid channel.", "an invalid channel should notify")
    current_is(terminal)
  end)

  for _, invalid_channel in ipairs({ false, "301", 1.5, -1 }) do
    select_visual(buf, "V", 1, 1, 1, 1)
    with_channel_mocks({ [terminal.buf] = invalid_channel }, function(sent)
      same(terminals.send({ position = "bottom" }), nil, "a non-positive integer channel should fail")
      same(#sent, 0, "an invalid channel should not receive data")
      same(stub.notifications[#stub.notifications], "Managed terminal has no valid channel.", "an invalid channel should notify")
      current_is(terminal)
    end)
  end

  select_visual(buf, "V", 1, 1, 1, 1)
  with_channel_mocks(setmetatable({}, {
    __index = function()
      error("channel lookup failed", 0)
    end,
  }), function(sent)
    same(terminals.send({ position = "bottom" }), nil, "a channel lookup error should fail")
    same(#sent, 0, "a failed channel lookup should not write data")
    same(stub.notifications[#stub.notifications], "Managed terminal has no valid channel.", "a lookup error should notify")
  end)

  select_visual(buf, "V", 2, 1, 2, 1)
  with_channel_mocks({ [terminal.buf] = 301 }, function()
    same(terminals.send({ position = "bottom" }), nil, "a channel send error should fail")
    same(stub.notifications[#stub.notifications], "Failed to send reference to managed terminal: test send failure", "a send failure should notify")
    current_is(terminal)
  end, function()
    error("test send failure", 0)
  end)
  terminal:hide()
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
  cd(directory("exit-focus-after-window-close"))
  local before = terminals.new("before")
  local closing = terminals.new("closing")
  local after = terminals.new("after")
  same(terminals.prev(), closing, "the closing terminal should be selectable")
  vim.api.nvim_win_close(closing.win, true)
  falsy(closing:win_valid(), "the focused terminal window should close before TermClose")
  closing:exit(0)
  current_is(before)
  same(terminals.next(), after, "the predecessor should remain selected after the exit handoff")
  current_is(after)

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

test("replaces visible unfocused edge terminals after successful exits", function()
  cd(directory("visible-edge-exit-handoff"))
  terminals.setup()

  local fallback = terminals.new("bottom-fallback", { position = "bottom" })
  local exiting = terminals.new("bottom-exiting", { position = "bottom" })
  local other_position = terminals.new("top", { position = "top" })
  local exiting_buffer = exiting.buf
  local other_position_win = other_position.win
  local other_position_hide_count = other_position.hide_count
  local opened = #stub.opened

  fallback:request("\027]9;fallback finished")
  same(tab_attention(), true, "the hidden fallback should retain its unread attention")
  vim.api.nvim_set_current_win(main_win)
  exiting:exit(0)

  falsy(vim.api.nvim_buf_is_valid(exiting_buffer), "the exited edge terminal should wipe its buffer")
  same(exiting.close_count, 1, "the exited edge terminal should close its Snacks object")
  truthy(fallback:win_valid(), "the adjacent terminal should replace the visible exited terminal")
  same(#stub.opened, opened, "the replacement should reuse the adjacent Snacks object")
  same(vim.api.nvim_get_current_win(), main_win, "the replacement should preserve editor focus")
  same(tab_attention(), true, "showing an unfocused fallback should preserve its unread attention")
  same(other_position.win, other_position_win, "another terminal position should keep its window")
  truthy(other_position:win_valid(), "another terminal position should remain visible")
  same(
    other_position.hide_count,
    other_position_hide_count,
    "replacing the exited terminal should not hide another position"
  )
end)

test("does not restore visible unfocused floats after successful exits", function()
  cd(directory("visible-float-exit"))
  terminals.setup()

  local fallback = terminals.new("float-fallback", { position = "float" })
  local exiting = terminals.new("float-exiting", { position = "float" })
  falsy(fallback:win_valid(), "the adjacent float should start hidden")

  vim.api.nvim_win_call(main_win, function()
    exiting:exit(0)
  end)

  falsy(exiting:buf_valid(), "the exited float should be destroyed")
  falsy(fallback:win_valid(), "an unfocused float should remain hidden after the visible float exits")
  same(vim.api.nvim_get_current_win(), main_win, "the float exit should leave focus in the editor")
end)

test("handles unfocused edge exits without an adjacent predecessor", function()
  cd(directory("edge-exit-boundaries"))
  terminals.setup()

  local single = terminals.new("single", { position = "bottom" })
  local opened = #stub.opened
  vim.api.nvim_set_current_win(main_win)
  vim.wait(20, function()
    return false
  end)
  single:exit(0)
  falsy(single:buf_valid(), "a lone successful edge terminal should be destroyed")
  same(#stub.opened, opened, "a lone edge exit should not create a replacement")
  same(vim.api.nvim_get_current_win(), main_win, "a lone unfocused edge exit should preserve editor focus")

  local first = terminals.new("first", { position = "top" })
  local successor = terminals.new("successor", { position = "top" })
  same(terminals.prev({ position = "top" }), first, "the first terminal should be visible before exiting")
  vim.api.nvim_set_current_win(main_win)
  vim.wait(20, function()
    return false
  end)
  first:exit(0)
  falsy(first:buf_valid(), "the first terminal should be destroyed after a successful exit")
  truthy(successor:win_valid(), "a successor should replace an exited terminal without a predecessor")
  same(vim.api.nvim_get_current_win(), main_win, "showing the successor should not steal editor focus")
  same(terminals.next({ position = "top" }), successor, "the successor should remain the selected fallback")
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

test("resolves default, configured, per-call, and inherited positions", function()
  local dir = directory("position-resolution")
  cd(dir)
  terminals.setup()

  local default_float = terminals.new("default-float")
  same(default_float.opts.win.position, "float", "float should remain the default position")

  vim.api.nvim_set_current_win(main_win)
  terminals.setup({ win = { position = "bottom" } })
  local bottom = terminals.new("bottom")
  same(bottom.opts.win.position, "bottom", "the configured position should apply outside managed terminals")

  terminals.setup({ win = { position = "right", width = 31 } })
  vim.cmd("TermNew inherited")
  local inherited = stub.opened[#stub.opened]
  same(inherited.opts.win.position, "bottom", "TermNew should inherit a focused terminal's position")
  same(bottom.opts.win.position, "bottom", "later setup calls should not mutate existing terminal options")

  vim.api.nvim_set_current_win(main_win)
  local configured_right = terminals.new("configured-right")
  same(configured_right.opts.win.position, "right", "the latest configured default should apply in the editor")
  same(configured_right.opts.win.width, 31, "a configured right width should reach Snacks initially")

  local explicit_top = terminals.new("explicit-top", { position = "top" })
  same(explicit_top.opts.win.position, "top", "a per-call position should override the focused position")
  truthy(configured_right:win_valid(), "creating at another edge should preserve the existing split")

  terminals.setup({ win = { position = "left", width = 29 } })
  same(explicit_top.opts.win.position, "top", "setup changes should not alter a per-call position")
  vim.api.nvim_set_current_win(main_win)
  local configured_left = terminals.new("configured-left")
  same(configured_left.opts.win.position, "left", "all documented edge positions should reach Snacks")
  same(configured_left.opts.win.width, 29, "a configured left width should reach Snacks initially")
end)

test("isolates navigation, visibility, winbars, and fallback by position", function()
  cd(directory("position-groups"))
  terminals.setup()

  local left_one = terminals.new("left-one", { position = "left" })
  local left_two = terminals.new("left-two", { position = "left" })
  falsy(left_one:win_valid(), "a newer left terminal should replace the previous left terminal")

  local right_one = terminals.new("right-one", { position = "right" })
  local right_two = terminals.new("right-two")
  truthy(left_two:win_valid(), "creating right terminals should leave the visible left terminal open")
  falsy(right_one:win_valid(), "a newer right terminal should replace the previous right terminal")
  truthy(right_two:win_valid(), "the newest right terminal should be visible")

  same(
    eval_winbar(left_two, 32).str,
    " left-one   left-two " .. string.rep(" ", 11),
    "the left winbar should contain only the left group"
  )
  same(
    eval_winbar(right_two, 32).str,
    " right-one   right-two " .. string.rep(" ", 9),
    "the right winbar should contain only the right group"
  )

  same(terminals.prev({ position = "left" }), left_one, "targeted previous should use only the left group")
  current_is(left_one)
  truthy(right_two:win_valid(), "switching left terminals should preserve the visible right terminal")
  falsy(left_two:win_valid(), "switching left terminals should hide the prior left terminal")

  same(terminals.next(), left_two, "an omitted position should inherit the focused left scope")
  current_is(left_two)
  truthy(right_two:win_valid(), "implicit left navigation should not hide the right terminal")

  same(terminals.prev({ position = "right" }), right_one, "the right active selection should be independent")
  current_is(right_one)
  truthy(left_two:win_valid(), "targeted right navigation should preserve the left terminal")
  same(terminals.next({ position = "right" }), right_two, "targeted next should stay within the right group")
  current_is(right_two)
  same(terminals.prev({ position = "right" }), right_one, "the right selection should wrap independently")
  current_is(right_one)

  same(terminals.toggle({ position = "left" }), left_two, "targeted toggle should use the left selection")
  falsy(left_two:win_valid(), "targeted toggle should hide only the selected left terminal")
  current_is(right_one)
  same(terminals.toggle({ position = "left" }), left_two, "targeted toggle should restore the left selection")
  current_is(left_two)
  truthy(right_one:win_valid(), "restoring the left terminal should leave the right terminal open")

  same(terminals.close(), left_two, "closing should remove the focused left terminal")
  current_is(left_one)
  truthy(right_one:win_valid(), "left fallback should not hide the right terminal")

  local right_focus_count = right_one.focus_count
  same(terminals.close(), left_one, "closing the final left terminal should not select another position")
  same(right_one.focus_count, right_focus_count, "closing an empty left group should not focus a right fallback")

  local top = terminals.new("top-only", { position = "top" })
  right_focus_count = right_one.focus_count
  top:exit(0)
  same(right_one.focus_count, right_focus_count, "a successful exit should not focus another position")
  truthy(right_one:win_valid(), "another position should remain visible after the top group exits")
end)

test("keeps edge terminals visible on WinLeave while floats auto-hide", function()
  cd(directory("position-winleave"))
  terminals.setup()

  local edge = terminals.new("edge", { position = "left" })
  local edge_hide_count = edge.hide_count
  vim.api.nvim_set_current_win(main_win)
  vim.wait(20, function()
    return false
  end)
  truthy(edge:win_valid(), "an edge terminal should remain visible after focus leaves it")
  same(edge.hide_count, edge_hide_count, "WinLeave should not hide an edge terminal")

  local float = terminals.new("float", { position = "float" })
  truthy(edge:win_valid(), "opening a float should not replace an edge terminal")
  vim.api.nvim_set_current_win(main_win)
  truthy(vim.wait(100, function()
    return not float:win_valid()
  end), "a float should still auto-hide on WinLeave")
  truthy(edge:win_valid(), "hiding the float should leave the edge terminal visible")

  same(terminals.toggle({ position = "float" }), float, "the float should remain reusable")
  local bottom = terminals.new("bottom", { position = "bottom" })
  current_is(bottom)
  falsy(float:win_valid(), "focusing another position should preserve float auto-hide behavior")
  truthy(edge:win_valid(), "a managed focus transition should keep other edge terminals visible")
end)

test("isolates the Cartesian product of directories and positions", function()
  local dir_a = directory("position-cartesian-a")
  local dir_b = directory("position-cartesian-b")
  cd(dir_a)
  terminals.setup()

  local a_left = terminals.new("a-left", { position = "left" })
  local b_left = terminals.new("b-left", { cwd = dir_b, position = "left" })
  local b_right = terminals.new("b-right", { cwd = dir_b, position = "right" })
  falsy(b_left:win_valid(), "a cross-directory left terminal should start hidden")
  falsy(b_right:win_valid(), "a cross-directory right terminal should start hidden")
  truthy(a_left:win_valid(), "background creation should preserve the foreground terminal")

  vim.api.nvim_set_current_win(main_win)
  same(terminals.prev({ position = "right" }), nil, "an empty position in directory A should stay empty")
  local a_right = terminals.toggle({ position = "right" })
  same(a_right.opts.cwd, dir_a, "empty targeted toggle should create in the applicable directory")
  same(a_right.opts.win.position, "right", "empty targeted toggle should create at the requested position")
  truthy(a_left:win_valid(), "creating directory A's right terminal should preserve its left terminal")

  vim.api.nvim_set_current_win(main_win)
  cd(dir_b)
  same(terminals.toggle({ position = "left" }), b_left, "directory B should retain its left selection")
  falsy(a_left:win_valid(), "showing directory B's left terminal should replace directory A's left terminal")
  truthy(a_right:win_valid(), "showing a left terminal should preserve the visible right terminal")

  same(terminals.toggle({ position = "right" }), b_right, "directory B should retain its right selection")
  falsy(a_right:win_valid(), "showing directory B's right terminal should replace directory A's right terminal")
  truthy(b_left:win_valid(), "showing a right terminal should preserve directory B's left terminal")
  same(eval_winbar(b_left, 20).str, " b-left " .. string.rep(" ", 12), "left winbar scope should be exact")
  same(eval_winbar(b_right, 20).str, " b-right " .. string.rep(" ", 11), "right winbar scope should be exact")
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

test("returns an empty winbar for missing, unmanaged, and stale windows", function()
  cd(directory("winbar-invalid-windows"))
  terminals.setup()
  local terminal = terminals.new("managed")
  local stale_win = terminal.win
  local had_statusline_winid = vim.fn.exists("g:statusline_winid") == 1
  local previous_statusline_winid = vim.g.statusline_winid

  with_cleanup(function()
    vim.g.statusline_winid = "not-a-window"
    same(terminals._winbar(), "%#NormalFloat#%=", "a non-numeric target should render only the fill")
    vim.g.statusline_winid = main_win
    same(terminals._winbar(), "%#NormalFloat#%=", "an unmanaged editor window should render only the fill")

    terminal:hide()
    vim.g.statusline_winid = stale_win
    same(terminals._winbar(), "%#NormalFloat#%=", "a stale managed window id should render only the fill")
  end, function()
    if had_statusline_winid then
      vim.g.statusline_winid = previous_statusline_winid
    else
      vim.g.statusline_winid = nil
    end
  end)
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

test("issues INFO notifications for OSC 9 requests", function()
  cd(directory("osc-9-notifications"))
  terminals.setup()

  local terminal = terminals.new("focused")
  local before = #stub.notification_calls

  terminal:request("\027]9;build finished")
  terminal:request("\027]9;Build: finished")
  terminal:request("\027]9;  Deploy Job  :   phase: complete  ")
  terminal:request("\027]9;Build:")
  terminal:request("\027]9;: body")
  terminal:request("\027]9;   : body")
  terminal:request("\027]9;4;1;50")
  terminal:request("\027]133;A")
  terminal:request("\027]9;")
  terminal:request("\027]9")

  same(#stub.notification_calls, before + 8, "only OSC 9 notifications should issue notifications")
  local expected = {
    {
      message = "build finished",
      level = vim.log.levels.INFO,
      opts = { title = "terminals" },
    },
    {
      message = "finished",
      level = vim.log.levels.INFO,
      opts = { title = "Build" },
    },
    {
      message = "phase: complete  ",
      level = vim.log.levels.INFO,
      opts = { title = "Deploy Job" },
    },
    {
      message = "a terminal needs attention",
      level = vim.log.levels.INFO,
      opts = { title = "Build" },
    },
    {
      message = ": body",
      level = vim.log.levels.INFO,
      opts = { title = "terminals" },
    },
    {
      message = "   : body",
      level = vim.log.levels.INFO,
      opts = { title = "terminals" },
    },
  }
  for index, notification in ipairs(expected) do
    same(stub.notification_calls[before + index], notification, "the OSC 9 notification should parse its title and body")
  end
  for index = before + 7, before + 8 do
    same(stub.notification_calls[index], {
      message = "a terminal needs attention",
      level = vim.log.levels.INFO,
      opts = { title = "terminals" },
    }, "an absent or empty OSC 9 message should use the default notification body")
  end
  same(tab_attention(), false, "a focused OSC 9 notification should not set unread attention")
end)

test("ignores malformed terminal requests and clears attention on direct entry", function()
  local dir = directory("osc-9-malformed")
  cd(dir)
  terminals.setup()

  local terminal = terminals.new("side", { position = "left" })
  vim.api.nvim_set_current_win(main_win)
  local notifications = #stub.notification_calls
  local request_handlers = vim.api.nvim_get_autocmds({
    event = "TermRequest",
    group = "terminals.nvim",
    buffer = terminal.buf,
  })
  same(#request_handlers, 1, "a managed terminal should have one lifecycle request handler")
  local malformed = {
    false,
    "not event data",
    {},
    { sequence = 9 },
  }
  for _, data in ipairs(malformed) do
    request_handlers[1].callback({
      buf = terminal.buf,
      data = data ~= false and data or nil,
    })
  end
  same(#stub.notification_calls, notifications, "malformed requests should not issue notifications")
  same(tab_attention(), false, "malformed requests should not set attention")

  local background_dir = directory("osc-9-malformed-background")
  cd(background_dir)
  local newer = terminals.new("newer", { cwd = vim.fs.normalize(dir), position = "left" })
  falsy(newer:win_valid(), "a newer terminal in another applicable cwd should start hidden")
  cd(dir)

  terminal:request("\027]9;ready")
  same(tab_attention(), true, "a valid unfocused request should set attention")
  local rendered = eval_winbar(terminal, 24)
  same(
    rendered.str,
    " side  !   newer " .. string.rep(" ", 7),
    "the unread request should appear before direct entry"
  )

  vim.api.nvim_set_current_win(terminal.win)
  same(tab_attention(), false, "entering the terminal window directly should clear attention")
  rendered = eval_winbar(terminal, 24)
  same(
    rendered.str,
    " side   newer " .. string.rep(" ", 10),
    "direct entry should remove attention and select the entered terminal"
  )
  same(terminals.next(), newer, "cycling should continue from the directly entered terminal")
end)

test("tracks unread OSC 9 notifications in the winbar", function()
  cd(directory("winbar-attention"))
  terminals.setup()
  vim.api.nvim_set_hl(0, "WinBarName", { fg = "#aaaaaa" })
  vim.api.nvim_set_hl(0, "WinBarNameActive", { fg = "#ffffff" })
  vim.api.nvim_set_hl(0, "TermBarStatus", { fg = "#ff0000" })
  vim.api.nvim_set_hl(0, "TermBarAttention", { fg = "#ffff00" })

  local background = terminals.new("background")
  local focused = terminals.new("focused")
  falsy(background:win_valid(), "the notifying terminal should be hidden before receiving OSC 9")

  focused:request("\027]9;focused notification")
  background:request("\027]9;4;1;50")
  background:request("\027]133;A")
  local rendered = eval_winbar(focused, 40)
  same(
    rendered.str,
    " background   focused " .. string.rep(" ", 18),
    "focused notifications, OSC 9 progress, and unrelated requests should be ignored"
  )
  same(tab_attention(), false, "ignored notifications should leave the tabpage attention false")

  background:request("\027]9;build finished")
  background:request("\027]9;another notification")
  background:exit(17)
  same(tab_attention(), true, "an unread notification should set the tabpage attention")
  rendered = eval_winbar(focused, 40)
  same(
    rendered.str,
    " background  17  !   focused " .. string.rep(" ", 11),
    "repeated background notifications should produce one padded attention box after the exit status"
  )
  same(highlight_spans(rendered), {
    { group = "WinBarName", start = 0 },
    { group = "TermBarStatus", start = 12 },
    { group = "TermBarAttention", start = 16 },
    { group = "NormalFloat", start = 19 },
    { group = "WinBarNameActive", start = 20 },
    { group = "NormalFloat", start = 29 },
  }, "attention should compose with inactive titles, exit statuses, separators, and the active title")

  same(terminals.prev(), background, "focusing the notifying terminal should select it")
  rendered = eval_winbar(background, 40)
  same(
    rendered.str,
    " background  17   focused " .. string.rep(" ", 14),
    "focusing a terminal should clear its unread attention"
  )
  same(tab_attention(), false, "reading the last notification should clear the tabpage attention")
end)

test("aggregates tabpage attention across terminal positions", function()
  cd(directory("tabpage-attention-positions"))
  terminals.setup()

  local floating = terminals.new("floating", { position = "float" })
  local side = terminals.new("side", { position = "left" })
  vim.api.nvim_set_current_win(main_win)

  floating:request("\027]9;floating finished")
  side:request("\027]9;side finished")
  same(tab_attention(), true, "attention in any position should mark the tabpage")

  same(terminals.toggle({ position = "float" }), floating, "the floating terminal should be focused")
  same(tab_attention(), true, "another attentive position should keep the tabpage marked")

  same(terminals.prev({ position = "left" }), side, "the side terminal should be focused")
  same(tab_attention(), false, "clearing the last attentive position should clear the tabpage")
end)

test("clears tabpage attention when attentive terminals exit or are wiped", function()
  cd(directory("tabpage-attention-removal"))
  terminals.setup()

  local successful = terminals.new("successful")
  local kept = terminals.new("kept")
  successful:request("\027]9;successful finished")
  same(tab_attention(), true, "a background terminal should mark the tabpage")
  successful:exit(0)
  same(tab_attention(), false, "a successful exit should clear its last attention")

  local wiped = terminals.new("wiped")
  same(terminals.prev(), kept, "the retained terminal should provide background focus")
  wiped:request("\027]9;wiped finished")
  same(tab_attention(), true, "the terminal to wipe should mark the tabpage")
  vim.api.nvim_buf_delete(wiped.buf, { force = true })
  same(tab_attention(), false, "wiping the last attentive terminal should clear the tabpage")

  local pruned = terminals.new("pruned")
  same(terminals.prev(), kept, "the retained terminal should stay available for pruning")
  pruned:request("\027]9;pruned finished")
  same(tab_attention(), true, "the terminal to prune should mark the tabpage")
  vim.cmd("noautocmd bwipeout! " .. pruned.buf)
  eval_winbar(kept, 20)
  same(tab_attention(), false, "pruning the last invalid attentive terminal should clear the tabpage")
end)

test("isolates owner-tab attention across local and global directory changes", function()
  local attentive_dir = directory("tabpage-attention-cwd")
  local unrelated_dir = directory("tabpage-attention-unrelated")
  cd(attentive_dir)
  terminals.setup()

  local first_tab = vim.api.nvim_get_current_tabpage()
  local first_background = terminals.new("first-background", { position = "left" })
  local first_focused = terminals.new("first-focused", { position = "left" })
  first_background:request("\027]9;first build finished")
  same(tab_attention(first_tab), true, "the terminal's owner tab should be marked")

  vim.cmd("tabnew")
  local second_tab = vim.api.nvim_get_current_tabpage()
  local second_main = vim.api.nvim_get_current_win()
  same(tab_attention(second_tab), false, "a same-cwd tab without its own attention should remain clear")

  local second_background = terminals.new("second-background", { position = "left" })
  local second_focused = terminals.new("second-focused", { position = "left" })
  second_background:request("\027]9;second build finished")
  same(tab_attention(second_tab), true, "the second tab should track only its own terminal attention")
  same(tab_attention(first_tab), true, "attention in the first tab should remain independent")

  vim.api.nvim_set_current_win(second_main)
  vim.cmd("tcd " .. vim.fn.fnameescape(unrelated_dir))
  same(tab_attention(second_tab), false, "a tab-local cwd mismatch should hide that owner's attention")
  same(tab_attention(first_tab), true, "another owner's attention should not be affected")
  vim.cmd("lcd " .. vim.fn.fnameescape(attentive_dir))
  same(tab_attention(second_tab), false, "window-local cwd changes should not override the tab-local cwd")
  vim.api.nvim_set_current_win(second_focused.win)
  vim.cmd("tcd " .. vim.fn.fnameescape(attentive_dir))
  same(tab_attention(second_tab), true, "restoring the owner tab cwd should restore its attention")

  vim.api.nvim_set_current_tabpage(first_tab)
  vim.api.nvim_set_current_win(main_win)
  cd(unrelated_dir)
  same(tab_attention(first_tab), false, "a global cwd mismatch should clear tabs without a local cwd")
  same(tab_attention(second_tab), true, "a tab-local cwd should remain independent of global changes")
  cd(attentive_dir)
  same(tab_attention(first_tab), true, "restoring the global cwd should restore owner attention")

  same(terminals.prev({ position = "left" }), first_background, "the first tab should clear its own unread terminal")
  same(tab_attention(first_tab), false, "reading the first tab's notification should clear only that tab")
  same(tab_attention(second_tab), true, "the second tab's unread state should remain set")

  vim.api.nvim_set_current_tabpage(second_tab)
  vim.api.nvim_set_current_win(second_focused.win)
  same(terminals.prev(), second_background, "the second tab should clear its own unread terminal")
  same(tab_attention(second_tab), false, "reading the second notification should clear its owner tab")
  vim.cmd("tabclose")
  truthy(first_focused:buf_valid(), "closing the second tab should preserve first-tab terminals")
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

test("keeps same-cwd terminal lists, selections, and edge visibility independent per tab", function()
  local dir = directory("tabs")
  cd(dir)
  terminals.setup()

  local first_tab = vim.api.nvim_get_current_tabpage()
  local first_one = terminals.new("first-one", { position = "left" })
  local first_two = terminals.new("first-two", { position = "left" })
  falsy(first_one:win_valid(), "the first tab should show only its selected left terminal")

  vim.cmd("tabnew")
  local second_tab = vim.api.nvim_get_current_tabpage()
  local second_one = terminals.new("second-one", { position = "left" })
  local second_two = terminals.new("second-two", { position = "left" })
  falsy(second_one:win_valid(), "the second tab should have its own selected left terminal")
  truthy(first_two:win_valid(), "opening the same position in another tab should preserve the first edge window")
  same(vim.api.nvim_win_get_tabpage(first_two.win), first_tab, "the first edge should remain in its owner tab")
  same(vim.api.nvim_win_get_tabpage(second_two.win), second_tab, "the second edge should be created in its owner tab")
  same(eval_winbar(second_two, 30).str, " second-one   second-two " .. string.rep(" ", 5), "the second winbar should list only its owner-tab group")

  same(terminals.prev({ position = "left" }), second_one, "cycling in the second tab should use its own list")
  current_is(second_one)
  truthy(first_two:win_valid(), "second-tab cycling should not hide the first tab's selected edge")

  vim.api.nvim_set_current_tabpage(first_tab)
  same(terminals.prev({ position = "left" }), first_one, "the first tab should retain its independent selection")
  current_is(first_one)
  truthy(second_one:win_valid(), "first-tab cycling should not hide the inactive tab's edge")
  same(eval_winbar(first_one, 30).str, " first-one   first-two " .. string.rep(" ", 7), "the first winbar should list only its owner-tab group")

  same(terminals.toggle({ position = "left" }), first_one, "toggle should hide only the current tab's selection")
  falsy(first_one:win_valid(), "the current tab's selected edge should be hidden")
  truthy(second_one:win_valid(), "toggling should preserve the same position in another tab")
  same(terminals.toggle({ position = "left" }), first_one, "toggle should restore only the current tab's selection")
  current_is(first_one)

  vim.api.nvim_set_current_tabpage(second_tab)
  vim.cmd("tabclose")
  truthy(vim.wait(100, function()
    return not second_one:buf_valid() and not second_two:buf_valid()
  end), "closing the second tab should destroy its independent list")
  truthy(first_one:buf_valid(), "closing the second tab should preserve the first tab's list")
end)

test("retains left and right widths independently per tab", function()
  local dir = directory("tab-widths")
  cd(dir)
  terminals.setup({ win = { width = 27 } })

  local first_tab = vim.api.nvim_get_current_tabpage()
  local first = terminals.new("first-width", { position = "left" })
  vim.api.nvim_win_set_width(first.win, 18)
  local first_replacement = terminals.new("first-width-replacement", { position = "left" })
  same(first_replacement.opts.win.width, 18, "the first tab should retain its resized left width")
  same(vim.api.nvim_win_get_width(first_replacement.win), 18, "the first tab's replacement should use its retained width")

  vim.cmd("tabnew")
  local second_tab = vim.api.nvim_get_current_tabpage()
  local second = terminals.new("second-width", { position = "left" })
  same(second.opts.win.width, 27, "a second tab should start from configuration rather than another tab's width")
  same(vim.api.nvim_win_get_width(second.win), 27, "the second tab should not inherit the first tab's live width")

  vim.api.nvim_win_set_width(second.win, 22)
  same(terminals.toggle({ position = "left" }), second, "the second tab should hide its own side terminal")
  same(terminals.toggle({ position = "left" }), second, "the second tab should restore its own side terminal")
  same(vim.api.nvim_win_get_width(second.win), 22, "the second tab should retain its own resized width")

  vim.api.nvim_set_current_tabpage(first_tab)
  truthy(first_replacement:win_valid(), "the first tab's edge should remain open across tab switches")
  same(vim.api.nvim_win_get_width(first_replacement.win), 18, "the second tab's resize should not alter the first tab")

  vim.api.nvim_win_set_width(first_replacement.win, 19)
  same(terminals.toggle({ position = "left" }), first_replacement, "the first tab should hide its own side terminal")
  same(terminals.toggle({ position = "left" }), first_replacement, "the first tab should restore its own side terminal")
  same(vim.api.nvim_win_get_width(first_replacement.win), 19, "the first tab should retain its latest width independently")

  vim.api.nvim_set_current_tabpage(second_tab)
  same(vim.api.nvim_win_get_width(second.win), 22, "the first tab's later resize should not alter the second tab")
  vim.cmd("tabclose")
  vim.wait(100, function()
    return not second:buf_valid()
  end)
end)

test("auto-hides floats on tab switches and restores only the owner object", function()
  local dir = directory("tab-floats")
  cd(dir)
  terminals.setup()

  local first_tab = vim.api.nvim_get_current_tabpage()
  local first = terminals.new("first-float", { position = "float" })
  local opened = #stub.opened

  vim.cmd("tabnew")
  local second_tab = vim.api.nvim_get_current_tabpage()
  truthy(vim.wait(100, function()
    return not first:win_valid()
  end), "switching tabs should auto-hide the departing tab's focused float")

  local second = terminals.toggle({ position = "float" })
  same(#stub.opened, opened + 1, "the second tab should create its own float instead of reusing the first")
  truthy(second ~= first, "same-cwd tabs should own distinct floating terminal objects")
  current_is(second)

  vim.api.nvim_set_current_tabpage(first_tab)
  truthy(vim.wait(100, function()
    return not second:win_valid()
  end), "leaving the second tab should auto-hide its focused float")
  same(terminals.toggle({ position = "float" }), first, "returning should restore the first tab's own float")
  same(#stub.opened, opened + 1, "restoring the owner float should not create another terminal")
  current_is(first)

  vim.api.nvim_set_current_tabpage(second_tab)
  vim.cmd("tabclose")
  truthy(vim.wait(100, function()
    return not second:buf_valid()
  end), "closing the second tab should destroy its hidden float")
end)

test("scopes untargeted and positioned TermSend delivery to the current tab", function()
  local dir = directory("tab-send")
  cd(dir)
  terminals.setup()

  local first_tab = vim.api.nvim_get_current_tabpage()
  for _, terminal in ipairs(stub.opened) do
    if terminal:win_valid() and vim.api.nvim_win_get_tabpage(terminal.win) == first_tab then
      terminal:hide()
    end
  end

  vim.cmd("tabnew")
  local second_tab = vim.api.nvim_get_current_tabpage()
  local other_tab_target = terminals.new("other-tab-target", { position = "right" })
  truthy(other_tab_target:win_valid(), "the other tab's explicit-position candidate should be visible")

  vim.api.nvim_set_current_tabpage(first_tab)
  local buf = source_buffer(dir, "tab-send.lua", { "selected" })
  with_channel_mocks(setmetatable({ [other_tab_target.buf] = 401 }, {
    __index = function()
      return 402
    end,
  }), function(sent)
    select_visual(buf, "V", 1, 1, 1, 1)
    same(terminals.send(), nil, "untargeted delivery should ignore visible terminals in another tab")
    same(#sent, 0, "an ignored other-tab terminal should receive no input")

    local opened = #stub.opened
    select_visual(buf, "V", 1, 1, 1, 1)
    local current_target = terminals.send({ position = "right" })
    truthy(current_target ~= other_tab_target, "positioned delivery should not use another tab's visible terminal")
    same(#stub.opened, opened + 1, "an empty current-tab position should create a current-tab terminal")
    same(vim.api.nvim_win_get_tabpage(current_target.win), first_tab, "the positioned target should belong to the current tab")
    same(sent, { { channel = 402, data = "tab-send.lua:1" } }, "only the current-tab target should receive the reference")
  end)

  truthy(other_tab_target:win_valid(), "current-tab delivery should preserve the other tab's edge window")
  vim.api.nvim_set_current_tabpage(second_tab)
  vim.cmd("tabclose")
  vim.wait(100, function()
    return not other_tab_target:buf_valid()
  end)
end)

test("restores an inactive owner tab's edge fallback without stealing focus", function()
  local dir = directory("tab-inactive-exit")
  cd(dir)
  terminals.setup()

  local owner_tab = vim.api.nvim_get_current_tabpage()
  local fallback = terminals.new("inactive-fallback", { position = "bottom" })
  local exiting = terminals.new("inactive-exiting", { position = "bottom" })

  vim.cmd("tabnew")
  local active_tab = vim.api.nvim_get_current_tabpage()
  local active_main = vim.api.nvim_get_current_win()
  local active_edge = terminals.new("active-edge", { position = "bottom" })
  vim.api.nvim_set_current_win(active_main)
  vim.wait(20, function()
    return false
  end)
  local active_win = vim.api.nvim_get_current_win()

  exiting:exit(0)

  falsy(exiting:buf_valid(), "the inactive tab's successful terminal should be destroyed")
  truthy(fallback:win_valid(), "the adjacent fallback should be restored in the inactive owner tab")
  same(vim.api.nvim_win_get_tabpage(fallback.win), owner_tab, "the fallback window should be recreated in its owner tab")
  same(vim.api.nvim_get_current_tabpage(), active_tab, "inactive fallback restoration should not switch tabs")
  same(vim.api.nvim_get_current_win(), active_win, "inactive fallback restoration should not steal focus")
  truthy(active_edge:win_valid(), "the active tab's terminal at the same position should remain visible")

  vim.cmd("tabclose")
  vim.wait(100, function()
    return not active_edge:buf_valid()
  end)
end)

test("destroys visible and hidden terminals when their owner tab closes", function()
  local dir = directory("tab-close")
  cd(dir)
  terminals.setup()

  local first_tab = vim.api.nvim_get_current_tabpage()
  local survivor = terminals.new("survivor", { position = "top" })
  vim.cmd("tabnew")
  local closed_tab = vim.api.nvim_get_current_tabpage()
  local hidden = terminals.new("hidden-on-close", { position = "right" })
  local visible = terminals.new("visible-on-close", { position = "right" })
  falsy(hidden:win_valid(), "one owned terminal should be hidden before its tab closes")
  truthy(visible:win_valid(), "one owned terminal should remain visible before its tab closes")
  local notifications = #stub.notifications

  vim.cmd("tabclose")
  falsy(vim.api.nvim_tabpage_is_valid(closed_tab), "the owner tab handle should become invalid immediately")
  truthy(vim.wait(200, function()
    return not hidden:buf_valid() and not visible:buf_valid()
  end), "tab closure should wipe both hidden and visible owned terminal buffers")
  same(hidden.close_count, 1, "tab closure should close the hidden terminal object")
  same(visible.close_count, 1, "tab closure should close the visible terminal object")
  falsy(hidden.process_running, "tab closure should terminate the hidden terminal job")
  falsy(visible.process_running, "tab closure should terminate the visible terminal job")
  same(#stub.notifications, notifications, "intentional tab cleanup should not report termination errors")
  same(vim.api.nvim_get_current_tabpage(), first_tab, "closing an owner tab should return to the remaining tab")
  truthy(survivor:buf_valid(), "terminals owned by remaining tabs should be preserved")
  truthy(survivor.process_running, "remaining-tab terminal jobs should keep running")
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

test("loads Snacks through require and reports terminal creation failures", function()
  cd(directory("snacks-loading-errors"))
  terminals.setup()

  local original_global = _G.Snacks
  local original_loaded = package.loaded.snacks
  local original_preload = package.preload.snacks

  local required
  local dependency_ok
  local dependency_error
  with_cleanup(function()
    _G.Snacks = nil
    package.loaded.snacks = stub
    required = terminals.new("required")
    same(required, stub.opened[#stub.opened], "the plugin should use a require-loaded Snacks module")

    _G.Snacks = nil
    package.loaded.snacks = nil
    package.preload.snacks = function()
      error("Snacks unavailable", 0)
    end
    dependency_ok, dependency_error = pcall(terminals.new, "missing")
  end, function()
    _G.Snacks = original_global
    package.loaded.snacks = original_loaded
    package.preload.snacks = original_preload
  end)
  falsy(dependency_ok, "terminal creation should fail when Snacks is unavailable")
  truthy(
    tostring(dependency_error):find("terminals.nvim requires folke/snacks.nvim", 1, true),
    "a missing dependency should produce the documented assertion"
  )

  same(terminals.toggle(), required, "the require-loaded terminal should remain managed after restoring globals")
  same(terminals.close(), required, "the restored require-loaded terminal should close normally")

  local original_open = stub.terminal.open
  local thrown_ok
  local thrown_error
  local nil_ok
  local nil_error
  with_cleanup(function()
    stub.terminal.open = function()
      error("terminal open exploded", 0)
    end
    thrown_ok, thrown_error = pcall(terminals.new, "throwing-open")
    stub.terminal.open = function()
      return nil
    end
    nil_ok, nil_error = pcall(terminals.new, "nil-open")
  end, function()
    stub.terminal.open = original_open
  end)

  falsy(thrown_ok, "Snacks terminal creation errors should propagate")
  truthy(tostring(thrown_error):find("terminal open exploded", 1, true), "the original open error should be retained")
  falsy(nil_ok, "a nil Snacks terminal should be rejected")
  truthy(
    tostring(nil_error):find("Snacks.terminal.open() did not return a terminal", 1, true),
    "a nil terminal should produce an explicit assertion"
  )

  local healthy = terminals.new("healthy")
  vim.api.nvim_set_current_win(main_win)
  truthy(vim.wait(100, function()
    return not healthy:win_valid()
  end), "an open failure should not leave WinLeave suppression enabled")
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

test("merges window options and enforces terminal invariants", function()
  local dir = directory("options")
  cd(dir)
  terminals.setup()
  local existing = terminals.new("defaults")
  same(existing.opts.win.width, nil, "width should be left to Snacks by default")

  local on_win = function() end
  local custom_new = { "N", function() end, mode = "n", desc = "Custom new" }
  local custom_close = { "C", function() end, mode = "t", desc = "Custom close" }
  local custom_prev = { "P", function() end, mode = { "n", "t" }, desc = "Custom previous" }
  local custom_next = { "X", function() end, mode = { "n", "t" }, desc = "Custom next" }
  terminals.setup({
    win = {
      border = "double",
      height = 0.6,
      width = 91,
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

  local terminal = terminals.new("configured", { position = "bottom" })
  local win = terminal.opts.win
  same(existing.opts.win.width, nil, "setup should not mutate existing terminal options")
  same(win.position, "bottom", "the resolved position should be enforced")
  same(win.width, 91, "Snacks window width should survive")
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

test("uses the floating background for focused and inactive split terminals", function()
  local dir = directory("split-backgrounds")
  cd(dir)
  local user_winhighlight = "Normal:UserNormal,CursorLine:Visual,NormalNC:UserNormalNC,FloatBorder:DiagnosticInfo"
  local expected = "CursorLine:Visual,FloatBorder:DiagnosticInfo,Normal:NormalFloat,NormalNC:NormalFloat"
  terminals.setup({
    win = {
      wo = {
        winhighlight = user_winhighlight,
      },
    },
  })

  local splits = {}
  for _, position in ipairs({ "top", "bottom", "left", "right" }) do
    local terminal = terminals.new(position, { position = position })
    splits[#splits + 1] = terminal
    same(terminal.opts.win.wo.winhighlight, expected, position .. " should enforce both background mappings")
    same(
      vim.api.nvim_get_option_value("winhighlight", { win = terminal.win }),
      expected,
      position .. " should apply the enforced mappings to its window"
    )
  end

  vim.api.nvim_set_current_win(main_win)
  for _, terminal in ipairs(splits) do
    same(
      vim.api.nvim_get_option_value("winhighlight", { win = terminal.win }),
      expected,
      terminal.opts.win.position .. " should keep the mappings while inactive"
    )
    terminal:focus()
    same(
      vim.api.nvim_get_option_value("winhighlight", { win = terminal.win }),
      expected,
      terminal.opts.win.position .. " should keep the mappings while focused"
    )
  end

  local recreated = splits[1]
  recreated:focus()
  same(terminals.toggle({ position = "top" }), recreated, "toggle should hide the focused top terminal")
  falsy(recreated:win_valid(), "the top terminal window should be hidden")
  same(terminals.toggle({ position = "top" }), recreated, "toggle should recreate the top terminal window")
  same(
    vim.api.nvim_get_option_value("winhighlight", { win = recreated.win }),
    expected,
    "a recreated split window should reapply the enforced mappings"
  )

  vim.api.nvim_set_current_win(main_win)
  local floating = terminals.new("float", { position = "float" })
  same(
    floating.opts.win.wo.winhighlight,
    user_winhighlight,
    "floating terminals should preserve the user-provided mappings unchanged"
  )
  same(
    vim.api.nvim_get_option_value("winhighlight", { win = floating.win }),
    user_winhighlight,
    "floating terminal windows should apply the unchanged user mappings"
  )
end)

test("keeps side terminal widths resizable", function()
  local dir = directory("resizable-side-widths")
  cd(dir)
  terminals.setup({
    win = {
      width = 27,
      on_win = function(snacks_win)
        snacks_win.user_on_win_called = true
      end,
      wo = {
        winfixwidth = true,
      },
    },
  })

  for _, position in ipairs({ "left", "right" }) do
    local terminal = terminals.new(position, { position = position })
    same(terminal.opts.win.wo.winfixwidth, false, position .. " should override a fixed user width")

    local resized_width = position == "left" and 18 or 22
    vim.api.nvim_win_set_width(terminal.win, resized_width)
    local replacement = terminals.new(position .. " replacement", { position = position })
    same(replacement.opts.win.width, resized_width, position .. " replacement should retain the live width")
    same(vim.api.nvim_win_get_width(replacement.win), resized_width, position .. " window width should not reset")

    local snacks_win = {
      opts = vim.deepcopy(replacement.opts.win),
      win = replacement.win,
      win_valid = function(self)
        return vim.api.nvim_win_is_valid(self.win)
      end,
    }
    snacks_win.opts.wo.winfixwidth = true
    vim.api.nvim_set_option_value("winfixwidth", true, { win = snacks_win.win })
    replacement.opts.win.on_win(snacks_win)
    truthy(snacks_win.user_on_win_called, position .. " should preserve the user on_win callback")
    same(snacks_win.opts.wo.winfixwidth, false, position .. " should correct Snacks' stored split default")
    same(
      vim.api.nvim_get_option_value("winfixwidth", { win = replacement.win }),
      false,
      position .. " Neovim window should remain resizable"
    )

    local toggled_width = resized_width + 1
    vim.api.nvim_win_set_width(replacement.win, toggled_width)
    same(terminals.toggle({ position = position }), replacement, position .. " toggle should hide the terminal")
    same(terminals.toggle({ position = position }), replacement, position .. " toggle should restore the terminal")
    same(vim.api.nvim_win_get_width(replacement.win), toggled_width, position .. " toggle should retain the live width")

    vim.api.nvim_set_current_win(main_win)
    replacement:exit(0)
    truthy(terminal:win_valid(), position .. " successful exit should show the adjacent terminal")
    same(
      vim.api.nvim_win_get_width(terminal.win),
      toggled_width,
      position .. " successful exit replacement should retain the live width"
    )
    same(vim.api.nvim_get_current_win(), main_win, position .. " successful exit should preserve editor focus")
    terminal:hide()
  end

  for _, position in ipairs({ "float", "top", "bottom" }) do
    local terminal = terminals.new(position, { position = position })
    same(
      terminal.opts.win.wo.winfixwidth,
      true,
      position .. " should preserve the user-provided winfixwidth"
    )
    same(type(terminal.opts.win.on_win), "function", position .. " should preserve the user on_win callback")
  end
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
