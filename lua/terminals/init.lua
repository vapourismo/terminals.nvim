local M = {}

local unpack = unpack or table.unpack

local function pack(...)
  return { n = select("#", ...), ... }
end

---@class terminals.Config
---@field width? integer
---@field win? table<string, any>

---@class terminals.Entry
---@field cwd string
---@field terminal snacks.terminal
---@field hiding boolean
---@field intentional_close boolean
---@field removed boolean

---@class terminals.Group
---@field terminals terminals.Entry[]
---@field active integer

local defaults = {
  width = 220,
  win = {},
}

---@type terminals.Config
local config = vim.deepcopy(defaults)

---@type table<string, terminals.Group>
local registry = {}

local next_count = 0
local suppress_winleave = 0

local function normalize_cwd()
  local cwd = vim.fn.getcwd()
  if vim.fs and vim.fs.normalize then
    return vim.fs.normalize(cwd)
  end
  return vim.fn.fnamemodify(cwd, ":p")
end

---@param terminal snacks.terminal
local function buf_valid(terminal)
  local ok, valid = pcall(terminal.buf_valid, terminal)
  return ok and valid == true
end

---@param terminal snacks.terminal
local function win_valid(terminal)
  local ok, valid = pcall(terminal.win_valid, terminal)
  return ok and valid == true
end

---@param cwd string
---@return terminals.Group?
local function prune(cwd)
  local group = registry[cwd]
  if not group then
    return nil
  end

  local selected = group.terminals[group.active]
  local old_active = group.active
  local terminals = {}
  for _, entry in ipairs(group.terminals) do
    if not entry.removed and buf_valid(entry.terminal) then
      terminals[#terminals + 1] = entry
    else
      entry.removed = true
    end
  end

  if #terminals == 0 then
    registry[cwd] = nil
    return nil
  end

  group.terminals = terminals
  group.active = math.min(old_active, #terminals)
  if selected and not selected.removed then
    for index, entry in ipairs(terminals) do
      if entry == selected then
        group.active = index
        break
      end
    end
  end
  return group
end

local function prune_all()
  local directories = vim.tbl_keys(registry)
  for _, cwd in ipairs(directories) do
    prune(cwd)
  end
end

---@param entry terminals.Entry
local function remove_entry(entry)
  if entry.removed then
    return
  end
  entry.removed = true

  local group = registry[entry.cwd]
  if not group then
    return
  end

  local removed_index
  for index, candidate in ipairs(group.terminals) do
    if candidate == entry then
      removed_index = index
      table.remove(group.terminals, index)
      break
    end
  end

  if #group.terminals == 0 then
    registry[entry.cwd] = nil
  elseif removed_index then
    if removed_index < group.active then
      group.active = group.active - 1
    elseif group.active > #group.terminals then
      group.active = #group.terminals
    end
  end
end

---@generic T
---@param callback fun(): T
---@return T
local function without_winleave(callback)
  suppress_winleave = suppress_winleave + 1
  local result = pack(pcall(callback))
  suppress_winleave = suppress_winleave - 1
  if not result[1] then
    error(result[2], 0)
  end
  return unpack(result, 2, result.n)
end

---@param except? snacks.terminal
local function hide_visible(except)
  prune_all()
  for _, group in pairs(registry) do
    for _, entry in ipairs(group.terminals) do
      local terminal = entry.terminal
      if terminal ~= except and win_valid(terminal) then
        terminal:hide()
      end
    end
  end
end

---@param entry terminals.Entry
local function focus(entry)
  without_winleave(function()
    hide_visible(entry.terminal)
    entry.terminal:show()
    entry.terminal:focus()
  end)
  return entry.terminal
end

local function terminal_action_keys()
  return {
    term_new = {
      "<D-n>",
      function()
        require("terminals").new()
      end,
      mode = { "n", "t" },
      desc = "New terminal",
    },
    term_close = {
      "<D-w>",
      function()
        require("terminals").close()
      end,
      mode = { "n", "t" },
      desc = "Close terminal",
    },
    term_prev = {
      "<D-{>",
      function()
        require("terminals").prev()
      end,
      mode = { "n", "t" },
      desc = "Previous terminal",
    },
    term_next = {
      "<D-}>",
      function()
        require("terminals").next()
      end,
      mode = { "n", "t" },
      desc = "Next terminal",
    },
  }
end

local function enforced_terminal_keys()
  return {
    q = false,
  }
end

local function window_options()
  local user_win = config.win or {}
  return vim.tbl_deep_extend("force", {}, user_win, {
    position = "float",
    width = config.width,
    wo = {
      foldenable = false,
      foldmethod = "manual",
    },
    keys = vim.tbl_deep_extend(
      "force",
      terminal_action_keys(),
      user_win.keys or {},
      enforced_terminal_keys()
    ),
  })
end

local function snacks()
  local module = rawget(_G, "Snacks")
  if not module then
    local ok, loaded = pcall(require, "snacks")
    module = ok and loaded or nil
  end
  assert(module and module.terminal and module.terminal.open, "terminals.nvim requires folke/snacks.nvim")
  return module
end

---@param entry terminals.Entry
local function attach(entry)
  local terminal = entry.terminal

  terminal:on("TermClose", function(_, event)
    if entry.intentional_close then
      return
    end

    local status = type(vim.v.event) == "table" and vim.v.event.status or nil
    if status == nil and type(event.data) == "table" then
      status = event.data.status
    end
    if status ~= 0 then
      snacks().notify.error("Terminal exited with code " .. status .. ".\nCheck for any errors.")
      return
    end

    remove_entry(entry)
    without_winleave(function()
      terminal:close()
    end)
    vim.cmd.checktime()
  end, { buf = true })

  terminal:on("BufWipeout", function()
    remove_entry(entry)
  end, { buf = true })

  terminal:on("WinLeave", function(_, event)
    if suppress_winleave > 0 or entry.hiding or entry.removed then
      return
    end

    if
      event.buf ~= terminal.buf
      or terminal.win ~= vim.api.nvim_get_current_win()
      or not win_valid(terminal)
    then
      return
    end

    entry.hiding = true
    local ok, err = pcall(terminal.hide, terminal)
    entry.hiding = false
    if not ok then
      error(err, 0)
    end
  end, { buf = true })
end

---Configure terminals created after this call.
---@param opts? terminals.Config
function M.setup(opts)
  config = vim.tbl_deep_extend("force", {}, defaults, opts or {})
end

---Create, select, and focus a terminal for the current directory.
---@param cmd? string|string[]
---@return snacks.terminal
function M.new(cmd)
  local cwd = normalize_cwd()
  next_count = next_count + 1

  local terminal
  without_winleave(function()
    hide_visible()
    terminal = snacks().terminal.open(cmd, {
      auto_close = false,
      cwd = cwd,
      count = next_count,
      win = window_options(),
    })
  end)
  assert(terminal, "Snacks.terminal.open() did not return a terminal")

  local group = registry[cwd]
  if not group then
    group = { terminals = {}, active = 1 }
    registry[cwd] = group
  end

  local entry = {
    cwd = cwd,
    terminal = terminal,
    hiding = false,
    intentional_close = false,
    removed = false,
  }
  group.terminals[#group.terminals + 1] = entry
  group.active = #group.terminals
  attach(entry)

  without_winleave(function()
    terminal:show()
    terminal:focus()
  end)
  return terminal
end

local function focused_entry()
  prune_all()
  local current_win = vim.api.nvim_get_current_win()
  local current_buf = vim.api.nvim_get_current_buf()
  for _, group in pairs(registry) do
    for _, entry in ipairs(group.terminals) do
      if entry.terminal.win == current_win and entry.terminal.buf == current_buf then
        return entry
      end
    end
  end
end

---Destroy the focused managed terminal.
---@return snacks.terminal?
function M.close()
  local entry = focused_entry()
  if not entry then
    return nil
  end

  entry.intentional_close = true
  remove_entry(entry)
  without_winleave(function()
    entry.terminal:close()
  end)
  return entry.terminal
end

---@param offset integer
---@return snacks.terminal?
local function cycle(offset)
  local group = prune(normalize_cwd())
  if not group then
    return nil
  end

  group.active = ((group.active - 1 + offset) % #group.terminals) + 1
  return focus(group.terminals[group.active])
end

---Select and focus the previous terminal for the current directory.
---@return snacks.terminal?
function M.prev()
  return cycle(-1)
end

---Select and focus the next terminal for the current directory.
---@return snacks.terminal?
function M.next()
  return cycle(1)
end

---Hide or show the selected terminal for the current directory.
---@return snacks.terminal
function M.toggle()
  local group = prune(normalize_cwd())
  if not group then
    return M.new()
  end

  local entry = group.terminals[group.active]
  if win_valid(entry.terminal) then
    without_winleave(function()
      entry.terminal:hide()
    end)
    return entry.terminal
  end
  return focus(entry)
end

return M
