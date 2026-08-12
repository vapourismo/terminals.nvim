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

---@class terminals.SendOptions
---@field position? string
---@field _command? table

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
---@field focused_before_leave boolean

---@class terminals.Group
---@field terminals terminals.Entry[]
---@field active integer

local defaults = {
  win = {
    position = "float",
  },
}

local positions = { "float", "top", "bottom", "left", "right" }
local valid_positions = {}
for _, position in ipairs(positions) do
  valid_positions[position] = true
end

---@type terminals.Config
local config = vim.deepcopy(defaults)

---@type table<string, table<string, terminals.Group>>
local registry = {}

-- Snacks recreates managed splits, so retain user-adjusted side widths across windows.
---@type table<string, integer>
local side_widths = {}

---@param cwd string
---@param position string
---@return terminals.Group?
local function group_for(cwd, position)
  local position_groups = registry[position]
  return position_groups and position_groups[cwd] or nil
end

---@param cwd string
---@param position string
---@return terminals.Group
local function ensure_group(cwd, position)
  registry[position] = registry[position] or {}
  registry[position][cwd] = registry[position][cwd] or { terminals = {}, active = 1 }
  return registry[position][cwd]
end

---@param cwd string
---@param position string
local function delete_group(cwd, position)
  local position_groups = registry[position]
  if not position_groups then
    return
  end

  position_groups[cwd] = nil
  if next(position_groups) == nil then
    registry[position] = nil
    side_widths[position] = nil
  end
end

---@param position? string
---@return terminals.Entry[]
local function registry_entries(position)
  local entries = {}
  local function append(position_groups)
    for _, group in pairs(position_groups or {}) do
      for _, entry in ipairs(group.terminals) do
        entries[#entries + 1] = entry
      end
    end
  end

  if position then
    append(registry[position])
  else
    for _, position_groups in pairs(registry) do
      append(position_groups)
    end
  end
  return entries
end

---@param entries terminals.Entry[]
---@param target terminals.Entry?
---@return integer?
local function entry_index(entries, target)
  for index, entry in ipairs(entries) do
    if entry == target then
      return index
    end
  end
end

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

---@param path string
---@return string?, string[]?
local function path_root_and_parts(path)
  path = path:gsub("\\", "/")

  local root
  local rest
  local server, share, unc_rest = path:match("^//([^/]+)/([^/]+)(.*)$")
  if server and share then
    root = "//" .. server .. "/" .. share
    rest = unc_rest
  else
    local drive, drive_rest = path:match("^([A-Za-z]:)(.*)$")
    if drive then
      root = drive:lower()
      rest = drive_rest
    elseif path:sub(1, 1) == "/" then
      root = "/"
      rest = path:sub(2)
    else
      return nil, nil
    end
  end

  local parts = {}
  for part in rest:gmatch("[^/]+") do
    parts[#parts + 1] = part
  end
  return root, parts
end

---@param cwd string
---@param path string
---@return string?
local function relative_path(cwd, path)
  local cwd_root, cwd_parts = path_root_and_parts(cwd)
  local path_root, path_parts = path_root_and_parts(path)
  if not cwd_root or not path_root or cwd_root:lower() ~= path_root:lower() then
    return nil
  end

  local case_insensitive = cwd_root ~= "/"
  local common = 0
  while common < #cwd_parts and common < #path_parts do
    local cwd_part = cwd_parts[common + 1]
    local path_part = path_parts[common + 1]
    if case_insensitive then
      cwd_part = cwd_part:lower()
      path_part = path_part:lower()
    end
    if cwd_part ~= path_part then
      break
    end
    common = common + 1
  end

  local parts = {}
  for _ = common + 1, #cwd_parts do
    parts[#parts + 1] = ".."
  end
  for index = common + 1, #path_parts do
    parts[#parts + 1] = path_parts[index]
  end
  return #parts == 0 and "." or table.concat(parts, "/")
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

local function synchronize_tab_attention()
  local attentive_directories = {}
  for _, entry in ipairs(registry_entries()) do
    if entry.attention and not entry.removed and buf_valid(entry.terminal) then
      attentive_directories[entry.cwd] = true
    end
  end

  local changed = false
  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    local tabnr = vim.api.nvim_tabpage_get_number(tabpage)
    local ok, cwd = pcall(vim.fn.getcwd, -1, tabnr)
    local attention = ok and attentive_directories[normalize_path(cwd)] == true
    local current_ok, current = pcall(vim.api.nvim_tabpage_get_var, tabpage, "attention")
    if not current_ok or current ~= attention then
      vim.api.nvim_tabpage_set_var(tabpage, "attention", attention)
      changed = true
    end
  end

  if changed then
    vim.cmd.redrawtabline()
  end
end

---@param position string
---@return boolean
local function is_side(position)
  return position == "left" or position == "right"
end

---@param position string
---@return boolean
local function is_split(position)
  return position == "top" or position == "bottom" or is_side(position)
end

---@param value any
---@return string
local function split_winhighlight(value)
  local mappings = {}
  if type(value) == "string" then
    for mapping in value:gmatch("[^,]+") do
      local source = mapping:match("^([^:]+):")
      if source ~= "Normal" and source ~= "NormalNC" then
        mappings[#mappings + 1] = mapping
      end
    end
  end
  mappings[#mappings + 1] = "Normal:NormalFloat"
  mappings[#mappings + 1] = "NormalNC:NormalFloat"
  return table.concat(mappings, ",")
end

---@param position string
---@param terminal snacks.terminal
local function remember_side_width(position, terminal)
  if not is_side(position) or not win_valid(terminal) then
    return
  end
  local ok, width = pcall(vim.api.nvim_win_get_width, terminal.win)
  if ok then
    side_widths[position] = width
  end
end

---@param position string
---@param terminal snacks.terminal
local function enforce_side_window(position, terminal)
  if not is_side(position) then
    return
  end

  if type(terminal.opts) == "table" then
    local win = type(terminal.opts.win) == "table" and terminal.opts.win or terminal.opts
    win.wo = type(win.wo) == "table" and win.wo or {}
    win.wo.winfixwidth = false
  end

  if win_valid(terminal) then
    pcall(vim.api.nvim_set_option_value, "winfixwidth", false, { win = terminal.win })
    if side_widths[position] then
      pcall(vim.api.nvim_win_set_width, terminal.win, side_widths[position])
    end
  end
end

---@param cwd string
---@param position string
---@return terminals.Group?
local function prune(cwd, position)
  local group = group_for(cwd, position)
  if not group then
    return nil
  end

  local selected = group.terminals[group.active]
  local old_active = group.active
  local terminals = {}
  local pruned_attention = false
  for _, entry in ipairs(group.terminals) do
    if not entry.removed and buf_valid(entry.terminal) then
      terminals[#terminals + 1] = entry
    else
      pruned_attention = pruned_attention or entry.attention
      entry.removed = true
    end
  end

  if pruned_attention then
    synchronize_tab_attention()
    vim.cmd.redrawstatus()
  end

  if #terminals == 0 then
    delete_group(cwd, position)
    return nil
  end

  group.terminals = terminals
  group.active = entry_index(terminals, selected) or math.min(old_active, #terminals)
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

---@param position string
local function remember_visible_side_width(position)
  if not is_side(position) then
    return
  end
  prune_all()
  for _, entry in ipairs(registry_entries(position)) do
    remember_side_width(position, entry.terminal)
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
  if entry.attention then
    synchronize_tab_attention()
    vim.cmd.redrawstatus()
  end

  local group = group_for(entry.cwd, entry.position)
  if not group then
    return nil, false
  end

  local selected = group.terminals[group.active]
  local removed_index = entry_index(group.terminals, entry)
  if not removed_index then
    return nil, false
  end

  local fallback = group.terminals[removed_index - 1] or group.terminals[removed_index + 1]
  table.remove(group.terminals, removed_index)

  if #group.terminals == 0 then
    delete_group(entry.cwd, entry.position)
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
  for _, entry in ipairs(registry_entries(position)) do
    local terminal = entry.terminal
    if terminal ~= except and win_valid(terminal) then
      remember_side_width(position, terminal)
      terminal:hide()
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
local function clear_attention(entry)
  if entry.attention then
    entry.attention = false
    synchronize_tab_attention()
    vim.cmd.redrawstatus()
  end
end

---@param entry terminals.Entry
local function select_entry(entry)
  local group = group_for(entry.cwd, entry.position)
  local index = group and entry_index(group.terminals, entry) or nil
  if index then
    group.active = index
  end
end

---@param entry terminals.Entry
local function focus(entry)
  local previous = focused_entry()
  select_entry(entry)
  without_winleave(function()
    hide_visible(entry.position, entry.terminal)
    entry.terminal:show()
    enforce_side_window(entry.position, entry.terminal)
    entry.terminal:focus()
  end)
  hide_departed_float(previous, entry.position)
  clear_attention(entry)
  return entry.terminal
end

---@param entry terminals.Entry
---@return boolean
local function entry_focused(entry)
  return entry.terminal.win == vim.api.nvim_get_current_win()
    and entry.terminal.buf == vim.api.nvim_get_current_buf()
end

---@param entry terminals.Entry
---@return boolean
local function consume_departing_focus(entry)
  local was_focused = entry.focused_before_leave or entry_focused(entry)
  entry.focused_before_leave = false
  return was_focused
end

---@return terminals.Entry?
focused_entry = function()
  prune_all()
  local current_win = vim.api.nvim_get_current_win()
  local current_buf = vim.api.nvim_get_current_buf()
  for _, entry in ipairs(registry_entries()) do
    if entry.terminal.win == current_win and entry.terminal.buf == current_buf then
      return entry
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

---@param entry terminals.Entry?
local function show_unfocused_edge_fallback(entry)
  if not entry or entry.removed or not buf_valid(entry.terminal) then
    return
  end

  local terminal = entry.terminal
  without_winleave(function()
    hide_visible(entry.position, terminal)

    -- A hidden Snacks window normally retains the enter behavior it had at
    -- creation. Disable it only while restoring a position whose terminal
    -- exited, so an unfocused edge split stays open without stealing focus.
    local opts = type(terminal.opts) == "table" and terminal.opts or nil
    local win = opts and (type(opts.win) == "table" and opts.win or opts) or nil
    local enter = win and win.enter
    if win then
      win.enter = false
    end
    local result = pack(pcall(terminal.show, terminal))
    if win then
      win.enter = enter
    end
    if not result[1] then
      error(result[2], 0)
    end

    enforce_side_window(entry.position, terminal)
  end)
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

  for _, entry in ipairs(registry_entries()) do
    if
      not entry.removed
      and entry.terminal.win == win
      and entry.terminal.buf == buf
      and buf_valid(entry.terminal)
    then
      return entry
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
  local enforced_wo = {
    foldenable = false,
    foldmethod = "manual",
    winbar = winbar_expression,
  }
  if is_split(position) then
    enforced_wo.winhighlight = split_winhighlight((user_win.wo or {}).winhighlight)
  end
  if is_side(position) then
    enforced_wo.winfixwidth = false
  end
  local win = vim.tbl_deep_extend("force", {}, user_win, {
    position = position,
    wo = enforced_wo,
    keys = vim.tbl_deep_extend(
      "force",
      terminal_action_keys(),
      user_win.keys or {},
      enforced_terminal_keys()
    ),
  })
  if is_side(position) then
    win.width = side_widths[position] or win.width
    local on_win = win.on_win
    win.on_win = function(snacks_win)
      local result = on_win and pack(on_win(snacks_win)) or { n = 0 }
      -- Snacks forces fixed dimensions for splits after merging window options.
      enforce_side_window(position, snacks_win)
      return unpack(result, 1, result.n)
    end
  end
  return win
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

---@param message string
local function notify_error(message)
  snacks().notify.error(message)
end

---@param message string
---@param title? string
local function notify_info(message, title)
  snacks().notify.info(message, { title = title or "terminals" })
end

---@param message string
local function notify_osc(message)
  local title
  local candidate, body = message:match("^([^:]*):(.*)$")
  if candidate then
    candidate = candidate:match("^%s*(.-)%s*$")
    if candidate ~= "" then
      title = candidate
      message = body:gsub("^%s+", "")
    end
  end

  notify_info(message ~= "" and message or "a terminal needs attention", title)
end

---@param buf integer
---@param position table
---@param linewise boolean
---@return table?
local function selection_position(buf, position, linewise)
  if type(position) ~= "table" then
    return nil
  end

  local position_buf = tonumber(position[1])
  local line = tonumber(position[2])
  local column = tonumber(position[3])
  if
    not position_buf
    or (position_buf ~= 0 and position_buf ~= buf)
    or not line
    or line < 1
    or line > vim.api.nvim_buf_line_count(buf)
  then
    return nil
  end

  if linewise then
    return { line = line, column = 1 }
  end
  if not column or column < 1 then
    return nil
  end

  local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, true)[1]
  if text == nil then
    return nil
  end
  local max_column = math.max(#text, 1)
  if column == vim.v.maxcol then
    column = max_column
  elseif column > max_column then
    return nil
  end
  return { line = line, column = column, line_length = #text }
end

---@param command? table
---@return table?
local function visual_selection(command)
  local mode
  local start_position
  local end_position
  if command then
    if command.range ~= 2 then
      notify_error("TermSend must be called from Visual mode.")
      return nil
    end

    mode = vim.fn.visualmode()
    start_position = vim.fn.getpos("'<")
    end_position = vim.fn.getpos("'>")
    if
      type(command.line1) ~= "number"
      or type(command.line2) ~= "number"
      or start_position[2] ~= command.line1
      or end_position[2] ~= command.line2
    then
      notify_error("TermSend must be called from Visual mode.")
      return nil
    end
  else
    mode = vim.fn.mode(1)
    start_position = vim.fn.getpos("v")
    end_position = vim.fn.getpos(".")
  end

  if mode == "\22" then
    notify_error("Blockwise Visual selections are not supported.")
    return nil
  end
  if mode ~= "v" and mode ~= "V" then
    notify_error("A characterwise or linewise Visual selection is required.")
    return nil
  end

  local buf = vim.api.nvim_get_current_buf()
  local linewise = mode == "V"
  local first = selection_position(buf, start_position, linewise)
  local last = selection_position(buf, end_position, linewise)
  if not first or not last then
    notify_error("Visual selection is missing or invalid.")
    return nil
  end
  if first.line > last.line or (first.line == last.line and first.column > last.column) then
    first, last = last, first
  end

  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    notify_error("Visual selection must be in a named buffer.")
    return nil
  end
  return {
    buf = buf,
    path = normalize_path(vim.fn.fnamemodify(name, ":p")),
    linewise = linewise,
    first = first,
    last = last,
  }
end

---@param selection table
---@param cwd string
---@return string?
local function selection_reference(selection, cwd)
  local relative = relative_path(cwd, selection.path)
  if not relative then
    notify_error("Buffer and terminal cwd are on incompatible filesystem roots.")
    return nil
  end

  local first = selection.first
  local last = selection.last
  local linewise = selection.linewise
    or (first.column == 1 and last.column == math.max(last.line_length, 1))
  if linewise then
    if first.line == last.line then
      return ("%s:%d"):format(relative, first.line)
    end
    return ("%s:%d-%d"):format(relative, first.line, last.line)
  end
  return ("%s:%d:%d-%d:%d"):format(relative, first.line, first.column, last.line, last.column)
end

---@param position? string
---@return terminals.Entry[]
local function visible_entries(position)
  prune_all()
  local entries = {}
  for _, entry in ipairs(registry_entries(position)) do
    if win_valid(entry.terminal) then
      entries[#entries + 1] = entry
    end
  end
  return entries
end

---@param terminal snacks.terminal
---@return integer?
local function terminal_channel(terminal)
  if not buf_valid(terminal) then
    return nil
  end

  local ok, channel
  if type(vim.api.nvim_get_option_value) == "function" then
    ok, channel = pcall(vim.api.nvim_get_option_value, "channel", { buf = terminal.buf })
  else
    ok, channel = pcall(vim.api.nvim_buf_get_option, terminal.buf, "channel")
  end
  if not ok or type(channel) ~= "number" or channel < 1 or channel % 1 ~= 0 then
    return nil
  end
  return channel
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

      local message = sequence == "\027]9" and "" or sequence:match("^\027%]9;(.*)$")
      if message == nil or message:match("^4;") then
        return
      end

      local focused = entry_focused(entry)
      notify_osc(message)
      if focused then
        return
      end

      if not entry.attention then
        entry.attention = true
        synchronize_tab_attention()
        vim.cmd.redrawstatus()
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = lifecycle_group,
    buffer = terminal.buf,
    callback = function()
      select_entry(entry)
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

      local was_focused = consume_departing_focus(entry)
      local was_visible = win_valid(terminal)
      local replace_visible_edge = was_visible and is_split(entry.position)
      remember_side_width(entry.position, terminal)
      local fallback, removed = remove_entry(entry, was_focused or replace_visible_edge)
      without_winleave(function()
        terminal:close()
      end)
      if removed and was_focused then
        focus_fallback(fallback)
      elseif removed and replace_visible_edge then
        show_unfocused_edge_fallback(fallback)
      end
      vim.cmd.checktime()
    end,
  })

  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = lifecycle_group,
    buffer = terminal.buf,
    callback = function()
      remember_side_width(entry.position, terminal)
      -- TermClose and BufWipeout can run after Neovim invalidates the terminal
      -- window, so retain whether its buffer was current while it is leaving.
      entry.focused_before_leave = suppress_winleave == 0
        and not entry.hiding
        and not entry.removed
        and terminal.buf == vim.api.nvim_get_current_buf()

      -- A later lifecycle event for an already hidden buffer must not reuse it.
      vim.schedule(function()
        entry.focused_before_leave = false
      end)
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = lifecycle_group,
    buffer = terminal.buf,
    callback = function()
      local was_focused = consume_departing_focus(entry)
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

vim.api.nvim_create_autocmd({ "TabNew", "DirChanged" }, {
  group = lifecycle_group,
  callback = synchronize_tab_attention,
})
synchronize_tab_attention()

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
    remember_visible_side_width(position)
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

  local group = ensure_group(cwd, position)
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
    focused_before_leave = false,
  }
  group.terminals[#group.terminals + 1] = entry
  group.active = #group.terminals
  attach(entry)

  without_winleave(function()
    if foreground then
      terminal:show()
      enforce_side_window(position, terminal)
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
  remember_side_width(entry.position, entry.terminal)
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
    remember_side_width(entry.position, entry.terminal)
    without_winleave(function()
      entry.terminal:hide()
    end)
    return entry.terminal
  end
  return focus(entry)
end

---Focus a managed terminal and insert a reference to the current Visual selection.
---@param opts? terminals.SendOptions
---@return snacks.terminal?
function M.send(opts)
  opts = opts or {}
  local position = opts.position
  if position ~= nil and not valid_positions[position] then
    notify_error("Invalid terminal position: " .. tostring(position) .. ".")
    return nil
  end

  local selection = visual_selection(opts._command)
  if not selection then
    return nil
  end

  local entry
  local target_cwd
  if position then
    local open = visible_entries(position)
    entry = open[1]
    if entry then
      target_cwd = entry.cwd
    else
      local cwd, resolved_position = applicable_scope(position)
      local group = prune(cwd, resolved_position)
      entry = group and group.terminals[group.active] or nil
      target_cwd = entry and entry.cwd or cwd
    end
  else
    local open = visible_entries()
    if #open == 0 then
      notify_error("No open managed terminal exists; specify a position to open one.")
      return nil
    end
    if #open > 1 then
      notify_error("Multiple open managed terminals exist; specify a position.")
      return nil
    end
    entry = open[1]
    target_cwd = entry.cwd
  end

  local reference = selection_reference(selection, target_cwd)
  if not reference then
    return nil
  end

  local terminal
  if entry then
    terminal = focus(entry)
  else
    terminal = M.new(nil, { cwd = target_cwd, position = position })
  end

  local channel = terminal_channel(terminal)
  if not channel then
    notify_error("Managed terminal has no valid channel.")
    return nil
  end

  local ok, err = pcall(vim.api.nvim_chan_send, channel, reference)
  if not ok then
    notify_error("Failed to send reference to managed terminal: " .. tostring(err))
    return nil
  end
  return terminal
end

return M
