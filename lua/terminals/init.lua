local M = {}

local unpack = unpack or table.unpack

local function pack(...)
  return { n = select("#", ...), ... }
end

---@class terminals.Config
---@field win? table<string, any>

---@class terminals.NewOptions
---@field title? string
---@field cwd? string
---@field position? string

---@class terminals.ScopeOptions
---@field position? string

---@class terminals.Entry
---@field cwd string
---@field position string
---@field cmd? string|string[]
---@field terminal snacks.terminal
---@field title? string
---@field exit_status? integer
---@field attention boolean
---@field hiding boolean
---@field intentional_close boolean
---@field removed boolean
---@field focused_before_wipe boolean

---@class terminals.Group
---@field terminals terminals.Entry[]
---@field active integer

local defaults = {
  win = {
    position = "float",
  },
}

---@type terminals.Config
local config = vim.deepcopy(defaults)

---@type table<string, table<string, terminals.Group>>
local registry = {}

local next_count = 0
local suppress_winleave = 0
local winbar_expression = "%!v:lua.require'terminals'._winbar()"
-- Snacks deletes its window augroup whenever a float is hidden, so terminal
-- lifecycle handlers must remain in a plugin-owned group.
local lifecycle_group = vim.api.nvim_create_augroup("terminals.nvim", { clear = true })

---@param path string
---@return string
local function normalize_path(path)
  if vim.fs and vim.fs.normalize then
    return vim.fs.normalize(path)
  end
  return vim.fn.fnamemodify(path, ":p")
end

---@return string
local function neovim_cwd()
  return normalize_path(vim.fn.getcwd())
end

---@param path string
---@return boolean
local function path_is_absolute(path)
  return path:sub(1, 1) == "/"
    or (vim.fn.has("win32") == 1 and path:match("^%a:[/\\]") ~= nil)
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
---@param position string
---@return terminals.Group?
local function prune(cwd, position)
  local position_groups = registry[position]
  local group = position_groups and position_groups[cwd] or nil
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
    position_groups[cwd] = nil
    if next(position_groups) == nil then
      registry[position] = nil
    end
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
  local positions = vim.tbl_keys(registry)
  for _, position in ipairs(positions) do
    local directories = vim.tbl_keys(registry[position])
    for _, cwd in ipairs(directories) do
      prune(cwd, position)
    end
  end
end

---@param entry terminals.Entry
---@param select_fallback? boolean
---@return terminals.Entry?, boolean
local function remove_entry(entry, select_fallback)
  if entry.removed then
    return nil, false
  end
  entry.removed = true

  local position_groups = registry[entry.position]
  local group = position_groups and position_groups[entry.cwd] or nil
  if not group then
    return nil, false
  end

  local selected = group.terminals[group.active]
  local removed_index
  for index, candidate in ipairs(group.terminals) do
    if candidate == entry then
      removed_index = index
      break
    end
  end

  if not removed_index then
    return nil, false
  end

  local fallback = group.terminals[removed_index - 1] or group.terminals[removed_index + 1]
  table.remove(group.terminals, removed_index)

  if #group.terminals == 0 then
    position_groups[entry.cwd] = nil
    if next(position_groups) == nil then
      registry[entry.position] = nil
    end
  elseif select_fallback or selected == entry then
    group.active = removed_index > 1 and removed_index - 1 or 1
  else
    if removed_index < group.active then
      group.active = group.active - 1
    elseif group.active > #group.terminals then
      group.active = #group.terminals
    end
  end
  return fallback, true
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

---@param position string
---@param except? snacks.terminal
local function hide_visible(position, except)
  prune_all()
  for _, group in pairs(registry[position] or {}) do
    for _, entry in ipairs(group.terminals) do
      local terminal = entry.terminal
      if terminal ~= except and win_valid(terminal) then
        terminal:hide()
      end
    end
  end
end

local focused_entry

---@param previous? terminals.Entry
---@param next_position string
local function hide_departed_float(previous, next_position)
  -- Managed focus changes suppress WinLeave while windows are rearranged, so
  -- preserve the float auto-hide contract explicitly across positions.
  if
    previous
    and previous.position == "float"
    and previous.position ~= next_position
    and win_valid(previous.terminal)
  then
    without_winleave(function()
      previous.terminal:hide()
    end)
  end
end

---@param entry terminals.Entry
local function focus(entry)
  local previous = focused_entry()
  without_winleave(function()
    hide_visible(entry.position, entry.terminal)
    entry.terminal:show()
    entry.terminal:focus()
  end)
  hide_departed_float(previous, entry.position)
  return entry.terminal
end

---@param entry terminals.Entry
---@return boolean
local function entry_focused(entry)
  return entry.terminal.win == vim.api.nvim_get_current_win()
    and entry.terminal.buf == vim.api.nvim_get_current_buf()
end

---@param entry terminals.Entry
local function clear_attention(entry)
  if entry.attention then
    entry.attention = false
    vim.cmd.redrawstatus()
  end
end

---@return terminals.Entry?
focused_entry = function()
  prune_all()
  local current_win = vim.api.nvim_get_current_win()
  local current_buf = vim.api.nvim_get_current_buf()
  for _, position_groups in pairs(registry) do
    for _, group in pairs(position_groups) do
      for _, entry in ipairs(group.terminals) do
        if entry.terminal.win == current_win and entry.terminal.buf == current_buf then
          return entry
        end
      end
    end
  end
end

---@return string
local function configured_position()
  return (config.win or {}).position or "float"
end

---@param position? string
---@return string, string, terminals.Entry?
local function applicable_scope(position)
  local entry = focused_entry()
  local cwd = entry and entry.cwd or neovim_cwd()
  return cwd, position or (entry and entry.position or configured_position()), entry
end

---@param cwd? string
---@param base string
---@return string
local function resolve_cwd(cwd, base)
  if cwd == nil then
    return base
  end

  local normalized = normalize_path(cwd)
  if path_is_absolute(normalized) then
    return normalized
  end
  return normalize_path(base .. "/" .. normalized)
end

---@param entry terminals.Entry?
local function focus_fallback(entry)
  if entry and not entry.removed and buf_valid(entry.terminal) then
    focus(entry)
  end
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

---@param title any
---@return string
local function escape_winbar_title(title)
  if type(title) ~= "string" then
    title = title == nil and "" or tostring(title)
  end
  return (title:gsub("%c", " "):gsub("%%", "%%%%"))
end

---@param entry terminals.Entry
---@return string
local function winbar_title(entry)
  if entry.title ~= nil then
    return entry.title
  end
  if type(entry.cmd) == "string" then
    return entry.cmd
  end
  if type(entry.cmd) == "table" then
    return table.concat(entry.cmd, " ")
  end
  return "terminal"
end

---@param win integer
---@return terminals.Entry?
local function entry_for_win(win)
  if win == 0 or not vim.api.nvim_win_is_valid(win) then
    return nil
  end

  local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
  if not ok then
    return nil
  end

  for _, position_groups in pairs(registry) do
    for _, group in pairs(position_groups) do
      for _, entry in ipairs(group.terminals) do
        if
          not entry.removed
          and entry.terminal.win == win
          and entry.terminal.buf == buf
          and buf_valid(entry.terminal)
        then
          return entry
        end
      end
    end
  end
  return nil
end

---Render the managed terminal winbar for Neovim's target statusline window.
---@return string
function M._winbar()
  local win = tonumber(vim.g.statusline_winid) or 0
  local entry = entry_for_win(win)
  local group = entry and prune(entry.cwd, entry.position) or nil
  if not group then
    return "%#NormalFloat#%="
  end

  local parts = {}
  for index, entry in ipairs(group.terminals) do
    local title = escape_winbar_title(winbar_title(entry))
    if index > 1 then
      parts[#parts + 1] = "%#NormalFloat# "
    end
    parts[#parts + 1] = index == group.active and "%#WinBarNameActive# " or "%#WinBarName# "
    parts[#parts + 1] = title
    parts[#parts + 1] = " "
    if entry.exit_status ~= nil then
      parts[#parts + 1] = "%#TermBarStatus# " .. entry.exit_status .. " "
    end
    if entry.attention then
      parts[#parts + 1] = "%#TermBarAttention# ! "
    end
  end
  parts[#parts + 1] = "%#NormalFloat#%="
  return table.concat(parts)
end

---@param position string
local function window_options(position)
  local user_win = config.win or {}
  return vim.tbl_deep_extend("force", {}, user_win, {
    position = position,
    wo = {
      foldenable = false,
      foldmethod = "manual",
      winbar = winbar_expression,
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

  vim.api.nvim_create_autocmd("TermRequest", {
    group = lifecycle_group,
    buffer = terminal.buf,
    callback = function(event)
      local data = type(event.data) == "table" and event.data or nil
      local sequence = data and data.sequence or nil
      if type(sequence) ~= "string" then
        return
      end

      local message = sequence:match("^\027%]9;(.*)$")
      if message == nil or message:match("^4;") or entry_focused(entry) then
        return
      end

      if not entry.attention then
        entry.attention = true
        vim.cmd.redrawstatus()
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = lifecycle_group,
    buffer = terminal.buf,
    callback = function()
      clear_attention(entry)
    end,
  })

  vim.api.nvim_create_autocmd("TermClose", {
    group = lifecycle_group,
    buffer = terminal.buf,
    callback = function(event)
      if entry.intentional_close then
        return
      end

      local status = type(vim.v.event) == "table" and vim.v.event.status or nil
      if status == nil and type(event.data) == "table" then
        status = event.data.status
      end
      if status ~= 0 then
        entry.exit_status = status
        vim.cmd.redrawstatus()
        snacks().notify.error("Terminal exited with code " .. status .. ".\nCheck for any errors.")
        return
      end

      local was_focused = entry_focused(entry)
      local fallback, removed = remove_entry(entry, was_focused)
      without_winleave(function()
        terminal:close()
      end)
      if removed and was_focused then
        focus_fallback(fallback)
      end
      vim.cmd.checktime()
    end,
  })

  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = lifecycle_group,
    buffer = terminal.buf,
    callback = function()
      -- BufWipeout runs after Neovim invalidates the terminal window, so retain
      -- whether its buffer was current while it is still leaving that window.
      entry.focused_before_wipe = suppress_winleave == 0
        and not entry.hiding
        and not entry.removed
        and terminal.buf == vim.api.nvim_get_current_buf()

      -- A later wipe of an already hidden buffer must not reuse this state.
      vim.schedule(function()
        entry.focused_before_wipe = false
      end)
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = lifecycle_group,
    buffer = terminal.buf,
    callback = function()
      local was_focused = entry.focused_before_wipe or entry_focused(entry)
      entry.focused_before_wipe = false
      local fallback, removed = remove_entry(entry, was_focused)
      if removed and was_focused then
        -- Window changes are unsafe until the wipe autocmd has completed.
        vim.schedule(function()
          focus_fallback(fallback)
        end)
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinLeave", {
    group = lifecycle_group,
    buffer = terminal.buf,
    callback = function(event)
      if entry.position ~= "float" or suppress_winleave > 0 or entry.hiding or entry.removed then
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
    end,
  })
end

---Configure terminals created after this call.
---@param opts? terminals.Config
function M.setup(opts)
  config = vim.tbl_deep_extend("force", {}, defaults, opts or {})
end

---Create a terminal for its effective directory, focusing it when that directory is applicable.
---@param cmd? string|string[]
---@param opts? terminals.NewOptions
---@return snacks.terminal
function M.new(cmd, opts)
  local requested_position = opts and opts.position or nil
  local base, position, previous = applicable_scope(requested_position)
  local cwd = resolve_cwd(opts and opts.cwd, base)
  local foreground = cwd == base
  next_count = next_count + 1

  local terminal
  without_winleave(function()
    if foreground then
      hide_visible(position)
    end
    local win = window_options(position)
    if not foreground then
      win.enter = false
    end
    terminal = snacks().terminal.open(cmd, {
      auto_close = false,
      cwd = cwd,
      count = next_count,
      win = win,
    })
  end)
  assert(terminal, "Snacks.terminal.open() did not return a terminal")

  local position_groups = registry[position]
  if not position_groups then
    position_groups = {}
    registry[position] = position_groups
  end

  local group = position_groups[cwd]
  if not group then
    group = { terminals = {}, active = 1 }
    position_groups[cwd] = group
  end

  local entry = {
    cwd = cwd,
    position = position,
    cmd = cmd,
    terminal = terminal,
    title = opts and opts.title,
    attention = false,
    hiding = false,
    intentional_close = false,
    removed = false,
    focused_before_wipe = false,
  }
  group.terminals[#group.terminals + 1] = entry
  group.active = #group.terminals
  attach(entry)

  without_winleave(function()
    if foreground then
      terminal:show()
      terminal:focus()
    else
      terminal:hide()
    end
  end)
  if foreground then
    hide_departed_float(previous, position)
  end
  return terminal
end

---Destroy the focused managed terminal.
---@return snacks.terminal?
function M.close()
  local entry = focused_entry()
  if not entry then
    return nil
  end

  entry.intentional_close = true
  local fallback, removed = remove_entry(entry, true)
  without_winleave(function()
    entry.terminal:close()
  end)
  if removed then
    focus_fallback(fallback)
  end
  return entry.terminal
end

---@param offset integer
---@param opts? terminals.ScopeOptions
---@return snacks.terminal?
local function cycle(offset, opts)
  local cwd, position = applicable_scope(opts and opts.position or nil)
  local group = prune(cwd, position)
  if not group then
    return nil
  end

  group.active = ((group.active - 1 + offset) % #group.terminals) + 1
  return focus(group.terminals[group.active])
end

---Select and focus the previous terminal for the applicable directory and position group.
---@param opts? terminals.ScopeOptions
---@return snacks.terminal?
function M.prev(opts)
  return cycle(-1, opts)
end

---Select and focus the next terminal for the applicable directory and position group.
---@param opts? terminals.ScopeOptions
---@return snacks.terminal?
function M.next(opts)
  return cycle(1, opts)
end

---Hide or show the selected terminal for the applicable directory and position group.
---@param opts? terminals.ScopeOptions
---@return snacks.terminal
function M.toggle(opts)
  local position_override = opts and opts.position or nil
  local cwd, position = applicable_scope(position_override)
  local group = prune(cwd, position)
  if not group then
    return M.new(nil, { position = position })
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
