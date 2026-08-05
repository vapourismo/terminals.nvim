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
