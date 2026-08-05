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
  return path
end

local function cd(path)
  vim.cmd("cd " .. vim.fn.fnameescape(path))
end

local function current_is(terminal)
  same(vim.api.nvim_get_current_win(), terminal.win, "terminal window should be focused")
  same(vim.api.nvim_get_current_buf(), terminal.buf, "terminal buffer should be focused")
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

  cd(dir_b)
  local other = terminals.new("other")
  same(terminals.prev(), other, "a one-terminal group should cycle to itself")

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

test("merges float options and enforces terminal invariants", function()
  local dir = directory("options")
  cd(dir)
  terminals.setup()
  local existing = terminals.new("defaults")
  same(existing.opts.win.width, 220, "default width")

  local on_win = function() end
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
      },
      keys = {
        q = "close",
        custom = { "x", "hide", mode = "n" },
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
  truthy(win.keys.custom, "custom key mappings should survive")
  same(win.keys.q, false, "the Snacks q mapping should be disabled")

  local normal = win.keys.term_normal
  same(normal[1], "<Esc>", "single Escape should enter Normal mode")
  same(normal.mode, "t", "Escape should be terminal-local")
  same(normal.expr, nil, "Escape should not retain Snacks' double-Escape expression")

  local escape = win.keys.term_escape
  same(escape[1], "<S-Esc>", "Shift-Escape mapping")
  same(escape.mode, "t", "Shift-Escape should be terminal-local")

  local original_send = vim.api.nvim_chan_send
  local sent = {}
  local channel
  local ok, err = xpcall(function()
    vim.api.nvim_chan_send = function(target, data)
      sent[#sent + 1] = { target, data }
    end

    escape[2]()
    same(#sent, 0, "Shift-Escape should ignore a missing channel")

    channel = vim.api.nvim_buf_call(terminal.buf, function()
      return vim.fn.jobstart({ vim.o.shell, "-c", "cat" }, { term = true })
    end)
    truthy(channel > 0, "test terminal channel should start")
    current_is(terminal)
    escape[2]()
    same(sent, { { channel, string.char(27) } }, "Shift-Escape should inject exactly one ESC byte")
  end, debug.traceback)
  vim.api.nvim_chan_send = original_send
  if channel and channel > 0 then
    pcall(vim.fn.jobstop, channel)
  end
  if not ok then
    error(err)
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
