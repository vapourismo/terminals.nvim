local M = {}

---@class terminals.Config
---@field position? string

---@class terminals.NewOptions
---@field title? string
---@field cwd? string
---@field group? boolean
---@field position? string
---@field env? table<string, string>

---@class terminals.ScopeOptions
---@field position? string

---@class terminals.SendOptions
---@field position? string
---@field _command? table

---@class terminals.Entry
---@field owner integer
---@field group_cwd string
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
---@field window_leave_candidate boolean
---@field visible_before_leave boolean
---@field departure_generation integer
---@field finalization_scheduled boolean
---@field finalization_done boolean
---@field finalization_checktime boolean
---@field finalization_was_focused boolean
---@field finalization_was_visible boolean

---@class terminals.Group
---@field terminals terminals.Entry[]
---@field active integer

local default_position = "float"

local positions = { "float", "top", "bottom", "left", "right" }
local valid_positions = {}
for _, position in ipairs(positions) do
  valid_positions[position] = true
end

local configured_position = default_position

---@type table<integer, table<string, table<string, terminals.Group>>>
local registry = {}

-- Snacks recreates managed splits, so retain user-adjusted side widths per tab.
---@type table<integer, table<string, integer>>
local side_widths = {}

---@param owner integer
---@param group_cwd string
---@param position string
---@return terminals.Group?
local function group_for(owner, group_cwd, position)
  local tab_registry = registry[owner]
  local position_groups = tab_registry and tab_registry[position]
  return position_groups and position_groups[group_cwd]
end

---@param owner integer
---@param group_cwd string
---@param position string
---@return terminals.Group
local function ensure_group(owner, group_cwd, position)
  registry[owner] = registry[owner] or {}
  registry[owner][position] = registry[owner][position] or {}
  registry[owner][position][group_cwd] = registry[owner][position][group_cwd]
    or { terminals = {}, active = 1 }
  return registry[owner][position][group_cwd]
end

---@param owner integer
---@param group_cwd string
---@param position string
local function delete_group(owner, group_cwd, position)
  local tab_registry = registry[owner]
  local position_groups = tab_registry and tab_registry[position]
  if not position_groups then
    return
  end

  position_groups[group_cwd] = nil
  if next(position_groups) == nil then
    tab_registry[position] = nil
    if side_widths[owner] then
      side_widths[owner][position] = nil
      if next(side_widths[owner]) == nil then
        side_widths[owner] = nil
      end
    end
  end
  if next(tab_registry) == nil then
    registry[owner] = nil
  end
end

---@param owner integer
---@param position? string
---@return terminals.Entry[]
local function registry_entries(owner, position)
  local entries = {}
  local position_groups = registry[owner] or {}
  if position then
    position_groups = { position_groups[position] }
  end
  for _, groups in pairs(position_groups) do
    for _, group in pairs(groups) do
      for _, entry in ipairs(group.terminals) do
        entries[#entries + 1] = entry
      end
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

local normalize_path = vim.fs.normalize

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
  local drive, drive_rest = path:match("^([A-Za-z]:)(.*)$")
  if server then
    root = "//" .. server .. "/" .. share
    rest = unc_rest
  elseif drive then
    root = drive:lower()
    rest = drive_rest
  elseif path:sub(1, 1) == "/" then
    root = "/"
    rest = path:sub(2)
  else
    return nil, nil
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
  local changed = false
  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    local tabnr = vim.api.nvim_tabpage_get_number(tabpage)
    local ok, cwd = pcall(vim.fn.getcwd, -1, tabnr)
    local effective_cwd = ok and normalize_path(cwd) or nil
    local attention = false
    for _, entry in ipairs(registry_entries(tabpage)) do
      if
        entry.group_cwd == effective_cwd
        and entry.attention
        and not entry.removed
        and buf_valid(entry.terminal)
      then
        attention = true
        break
      end
    end

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

local function redraw_attention()
  synchronize_tab_attention()
  vim.cmd.redrawstatus()
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

local managed_winhighlight = "Normal:NormalFloat,NormalNC:NormalFloat"

---@param owner integer
---@param position string
---@param terminal snacks.terminal
local function remember_side_width(owner, position, terminal)
  if not is_side(position) or not win_valid(terminal) then
    return
  end
  side_widths[owner] = side_widths[owner] or {}
  side_widths[owner][position] = vim.api.nvim_win_get_width(terminal.win)
end

---@param owner integer
---@param position string
---@param terminal snacks.terminal
local function enforce_side_window(owner, position, terminal)
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
    local width = side_widths[owner] and side_widths[owner][position]
    if width then
      pcall(vim.api.nvim_win_set_width, terminal.win, width)
    end
  end
end

---@param owner integer
---@param group_cwd string
---@param position string
---@return terminals.Group?
local function prune(owner, group_cwd, position)
  local group = group_for(owner, group_cwd, position)
  if not group then
    return nil
  end

  local selected = group.terminals[group.active]
  local old_active = group.active
  local terminals = {}
  local pruned_attention = false
  for _, entry in ipairs(group.terminals) do
    if
      not entry.removed
      and (buf_valid(entry.terminal) or (entry.finalization_scheduled and not entry.finalization_done))
    then
      terminals[#terminals + 1] = entry
    else
      pruned_attention = pruned_attention or entry.attention
      entry.removed = true
    end
  end

  if pruned_attention then
    redraw_attention()
  end

  if #terminals == 0 then
    delete_group(owner, group_cwd, position)
    return nil
  end

  group.terminals = terminals
  group.active = entry_index(terminals, selected) or math.min(old_active, #terminals)
  return group
end

---@param owner? integer
local function prune_all(owner)
  local owners = owner and { owner } or vim.tbl_keys(registry)
  for _, tabpage in ipairs(owners) do
    local tab_registry = registry[tabpage]
    for _, position in ipairs(vim.tbl_keys(tab_registry or {})) do
      for _, group_cwd in ipairs(vim.tbl_keys(tab_registry[position])) do
        prune(tabpage, group_cwd, position)
      end
    end
  end
end

---@param owner integer
---@param position string
local function remember_visible_side_width(owner, position)
  if not is_side(position) then
    return
  end
  prune_all(owner)
  for _, entry in ipairs(registry_entries(owner, position)) do
    remember_side_width(owner, position, entry.terminal)
  end
end

---@param entry terminals.Entry
---@param select_fallback? boolean
---@return terminals.Entry?
local function remove_entry(entry, select_fallback)
  if entry.removed then
    return nil
  end
  entry.removed = true
  if entry.attention then
    redraw_attention()
  end

  local group = group_for(entry.owner, entry.group_cwd, entry.position)
  if not group then
    return nil
  end

  local removed_index = entry_index(group.terminals, entry)
  if not removed_index then
    return nil
  end

  local fallback = group.terminals[removed_index - 1] or group.terminals[removed_index + 1]
  table.remove(group.terminals, removed_index)

  if #group.terminals == 0 then
    delete_group(entry.owner, entry.group_cwd, entry.position)
  elseif select_fallback or removed_index == group.active then
    group.active = removed_index > 1 and removed_index - 1 or 1
  elseif removed_index < group.active then
    group.active = group.active - 1
  end
  return fallback
end

---@param callback function
local function without_winleave(callback)
  suppress_winleave = suppress_winleave + 1
  local ok, err = pcall(callback)
  suppress_winleave = suppress_winleave - 1
  if not ok then
    error(err, 0)
  end
end

---@param owner integer
---@param position string
---@param except? snacks.terminal
local function hide_visible(owner, position, except)
  prune_all(owner)
  for _, entry in ipairs(registry_entries(owner, position)) do
    local terminal = entry.terminal
    if terminal ~= except and win_valid(terminal) then
      remember_side_width(owner, position, terminal)
      terminal:hide()
    end
  end
end

---@return terminals.Entry?
local function focused_entry()
  local owner = vim.api.nvim_get_current_tabpage()
  prune_all(owner)
  local current_win = vim.api.nvim_get_current_win()
  local current_buf = vim.api.nvim_get_current_buf()
  for _, entry in ipairs(registry_entries(owner)) do
    if entry.terminal.win == current_win and entry.terminal.buf == current_buf then
      return entry
    end
  end
end

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
---@param attention boolean
local function set_attention(entry, attention)
  if entry.attention == attention then
    return
  end
  entry.attention = attention
  redraw_attention()
end

---@param entry terminals.Entry
local function select_entry(entry)
  local group = group_for(entry.owner, entry.group_cwd, entry.position)
  local index = group and entry_index(group.terminals, entry)
  if index then
    group.active = index
  end
end

---@param entry terminals.Entry
local function focus(entry)
  local previous = focused_entry()
  select_entry(entry)
  without_winleave(function()
    hide_visible(entry.owner, entry.position, entry.terminal)
    entry.terminal:show()
    enforce_side_window(entry.owner, entry.position, entry.terminal)
    entry.terminal:focus()
  end)
  hide_departed_float(previous, entry.position)
  set_attention(entry, false)
  return entry.terminal
end

---@param entry terminals.Entry
---@return boolean
local function entry_focused(entry)
  return entry.terminal.win == vim.api.nvim_get_current_win()
    and entry.terminal.buf == vim.api.nvim_get_current_buf()
end

---@param entry terminals.Entry
local function leave_failed_terminal_mode(entry)
  if entry.exit_status ~= nil and entry.exit_status ~= 0 and entry_focused(entry) then
    vim.cmd.stopinsert()
  end
end

---@param entry terminals.Entry
local function clear_departing_state(entry)
  entry.focused_before_leave = false
  entry.window_leave_candidate = false
  entry.visible_before_leave = false
end

---@param entry terminals.Entry
---@return boolean, boolean
local function consume_departing_state(entry)
  local invalidated_departure = entry.window_leave_candidate
    and (not win_valid(entry.terminal) or not buf_valid(entry.terminal))
  local was_focused = entry.focused_before_leave or entry_focused(entry) or invalidated_departure
  local was_visible = entry.visible_before_leave or win_valid(entry.terminal)
  entry.departure_generation = entry.departure_generation + 1
  clear_departing_state(entry)
  return was_focused, was_visible
end

---@param position? string
---@return integer, string, string, terminals.Entry?
local function applicable_scope(position)
  local owner = vim.api.nvim_get_current_tabpage()
  local entry = focused_entry()
  local group_cwd = entry and entry.group_cwd or normalize_path(vim.fn.getcwd())
  return owner, group_cwd, position or (entry and entry.position) or configured_position, entry
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
  if
    entry
    and entry.owner == vim.api.nvim_get_current_tabpage()
    and not entry.removed
    and buf_valid(entry.terminal)
  then
    focus(entry)
  end
end

---@param owner integer
---@param avoid_position string
---@return integer?
local function owner_execution_window(owner, avoid_position)
  if not vim.api.nvim_tabpage_is_valid(owner) then
    return nil
  end

  local avoided = {}
  for _, entry in ipairs(registry_entries(owner, avoid_position)) do
    if win_valid(entry.terminal) then
      avoided[entry.terminal.win] = true
    end
  end

  local windows = vim.api.nvim_tabpage_list_wins(owner)
  for _, win in ipairs(windows) do
    local win_config = vim.api.nvim_win_get_config(win)
    if not avoided[win] and win_config.relative == "" then
      return win
    end
  end
  return windows[1]
end

---@param entry terminals.Entry?
local function show_unfocused_edge_fallback(entry)
  if
    not entry
    or entry.removed
    or not vim.api.nvim_tabpage_is_valid(entry.owner)
    or not buf_valid(entry.terminal)
  then
    return
  end

  local terminal = entry.terminal
  without_winleave(function()
    local function show()
      hide_visible(entry.owner, entry.position, terminal)

      -- A hidden Snacks window normally retains the enter behavior it had at
      -- creation. Disable it only while restoring a position whose terminal
      -- exited, so an unfocused edge split stays open without stealing focus.
      local opts = type(terminal.opts) == "table" and terminal.opts or nil
      local win = opts and (type(opts.win) == "table" and opts.win or opts) or nil
      local enter = win and win.enter
      if win then
        win.enter = false
      end
      local ok, err = pcall(terminal.show, terminal)
      if win then
        win.enter = enter
      end
      if not ok then
        error(err, 0)
      end

      enforce_side_window(entry.owner, entry.position, terminal)
    end

    if entry.owner == vim.api.nvim_get_current_tabpage() then
      show()
      return
    end

    local execution_win = owner_execution_window(entry.owner, entry.position)
    if execution_win then
      vim.api.nvim_win_call(execution_win, show)
    end
  end)
end

local function terminal_action(key, method, description)
  return {
    key,
    function()
      M[method]()
    end,
    mode = { "n", "t" },
    desc = description,
  }
end

local function terminal_action_keys()
  return {
    term_new = terminal_action("<D-n>", "new", "New terminal"),
    term_close = terminal_action("<D-w>", "close", "Close terminal"),
    term_prev = terminal_action("<D-{>", "prev", "Previous terminal"),
    term_next = terminal_action("<D-}>", "next", "Next terminal"),
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

  local buf = vim.api.nvim_win_get_buf(win)
  local owner = vim.api.nvim_win_get_tabpage(win)
  for _, entry in ipairs(registry_entries(owner)) do
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
  local target = entry_for_win(win)
  local group = target and prune(target.owner, target.group_cwd, target.position)
  if not group then
    return "%#NormalFloat#%="
  end

  local gap_highlight = entry_focused(target) and "TermBarGapFocused" or "TermBarGap"
  local gap = "%#" .. gap_highlight .. "#"
  local parts = { gap .. " " }
  for index, entry in ipairs(group.terminals) do
    local title = escape_winbar_title(winbar_title(entry))
    if index > 1 then
      parts[#parts + 1] = gap .. " "
    end
    local title_highlight = "TermBarName"
    if index == group.active then
      title_highlight = entry_focused(entry) and "TermBarNameFocused" or "TermBarNameActive"
    end
    parts[#parts + 1] = "%#" .. title_highlight .. "# "
    parts[#parts + 1] = title
    parts[#parts + 1] = " "
    if entry.exit_status ~= nil then
      parts[#parts + 1] = "%#TermBarStatus# " .. entry.exit_status .. " "
    end
    if entry.attention then
      parts[#parts + 1] = "%#TermBarAttention# ! "
    end
  end
  parts[#parts + 1] = gap .. "%="
  return table.concat(parts)
end

---@param owner integer
---@param position string
local function window_options(owner, position)
  local wo = {
    foldenable = false,
    foldmethod = "manual",
    winbar = winbar_expression,
  }
  wo.winhighlight = managed_winhighlight
  if is_side(position) then
    wo.winfixwidth = false
  end

  local keys = terminal_action_keys()
  keys.q = false
  local win = {
    position = position,
    wo = wo,
    keys = keys,
  }
  if is_side(position) then
    win.width = side_widths[owner] and side_widths[owner][position]
    win.on_win = function(snacks_win)
      -- Snacks forces fixed dimensions for splits after merging window options.
      enforce_side_window(owner, position, snacks_win)
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

  snacks().notify.info(message ~= "" and message or "a terminal needs attention", {
    title = title or "terminals",
  })
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
    mode = vim.fn.visualmode()
    start_position = vim.fn.getpos("'<")
    end_position = vim.fn.getpos("'>")
    if
      command.range ~= 2
      or type(command.line1) ~= "number"
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

---@param owner integer
---@param position? string
---@return terminals.Entry[]
local function visible_entries(owner, position)
  prune_all(owner)
  local entries = {}
  for _, entry in ipairs(registry_entries(owner, position)) do
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
---@param event table
---@param terminal_buf integer
local function record_departing_state(entry, event, terminal_buf)
  local terminal = entry.terminal
  if
    suppress_winleave > 0
    or entry.hiding
    or entry.intentional_close
    or entry.removed
    or event.buf ~= terminal_buf
  then
    return
  end

  local event_name = event.event
  local leaves_current_window = event_name == "WinLeave"
  if leaves_current_window then
    -- WinLeave also fires for an ordinary move to the editor. Keep it as a
    -- candidate until a buffer/window invalidation confirms that lifecycle
    -- teardown, rather than letting an immediate background exit steal focus.
    entry.window_leave_candidate = true
  end
  local confirms_teardown = event_name == "BufWinLeave" or event_name == "BufWipeout"
  local was_focused = confirms_teardown
    and (vim.api.nvim_get_current_buf() == terminal_buf or entry.window_leave_candidate)
  local was_visible = leaves_current_window
    or event_name == "BufLeave"
    or event_name == "BufWinLeave"
    or win_valid(terminal)

  entry.focused_before_leave = entry.focused_before_leave or was_focused
  entry.visible_before_leave = entry.visible_before_leave or was_visible
  entry.departure_generation = entry.departure_generation + 1
  local generation = entry.departure_generation

  -- Ordinary focus changes and hides must not make a later background exit look
  -- focused. Lifecycle events from the same close/wipe transition consume the
  -- marker before this scheduled reset runs.
  vim.schedule(function()
    if entry.departure_generation == generation and not entry.finalization_scheduled then
      clear_departing_state(entry)
    end
  end)
end

---@param entry terminals.Entry
---@param checktime boolean
local function schedule_finalization(entry, checktime)
  if entry.finalization_done or entry.intentional_close then
    return
  end

  local was_focused, was_visible = consume_departing_state(entry)
  entry.finalization_was_focused = entry.finalization_was_focused or was_focused
  entry.finalization_was_visible = entry.finalization_was_visible or was_visible
  entry.finalization_checktime = entry.finalization_checktime or checktime

  if entry.finalization_scheduled then
    return
  end
  entry.finalization_scheduled = true

  -- TermClose can still be followed by terminal-mode teardown, window closure,
  -- and BufWipeout. Wait until that lifecycle stack has unwound before closing
  -- Snacks or installing the adjacent terminal in the vacated position.
  vim.schedule(function()
    if entry.finalization_done or entry.intentional_close then
      return
    end
    entry.finalization_done = true

    local replace_visible_edge = entry.finalization_was_visible and is_split(entry.position)
    remember_side_width(entry.owner, entry.position, entry.terminal)
    local fallback = remove_entry(entry, entry.finalization_was_focused or replace_visible_edge)

    local close_ok, close_error = pcall(function()
      without_winleave(function()
        entry.terminal:close()
      end)
    end)

    if entry.finalization_was_focused then
      focus_fallback(fallback)
    elseif replace_visible_edge then
      show_unfocused_edge_fallback(fallback)
    end
    if entry.finalization_checktime then
      vim.cmd.checktime()
    end
    if not close_ok then
      error(close_error, 0)
    end
  end)
end

---@param entry terminals.Entry
local function attach(entry)
  local terminal = entry.terminal
  -- Keep the creation-time buffer independently of Snacks' mutable handle so
  -- late leave/wipe callbacks can still identify this terminal.
  local terminal_buf = terminal.buf

  ---@param events string|string[]
  ---@param callback function
  local function on_terminal_event(events, callback)
    vim.api.nvim_create_autocmd(events, {
      group = lifecycle_group,
      buffer = terminal_buf,
      callback = callback,
    })
  end

  on_terminal_event("TermRequest", function(event)
    local sequence = type(event.data) == "table" and event.data.sequence
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

    set_attention(entry, true)
  end)

  on_terminal_event({ "BufEnter", "WinEnter" }, function()
    entry.departure_generation = entry.departure_generation + 1
    clear_departing_state(entry)
    select_entry(entry)
    set_attention(entry, false)
  end)

  on_terminal_event("TermEnter", function()
    leave_failed_terminal_mode(entry)
  end)

  on_terminal_event("TermClose", function(event)
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
      leave_failed_terminal_mode(entry)
      snacks().notify.error("Terminal exited with code " .. status .. ".\nCheck for any errors.")
      return
    end

    schedule_finalization(entry, true)
  end)

  on_terminal_event({ "BufLeave", "BufWinLeave" }, function(event)
    remember_side_width(entry.owner, entry.position, terminal)
    record_departing_state(entry, event, terminal_buf)
  end)

  on_terminal_event("BufWipeout", function(event)
    record_departing_state(entry, event, terminal_buf)
    schedule_finalization(entry, false)
  end)

  on_terminal_event("WinLeave", function(event)
    record_departing_state(entry, event, terminal_buf)
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
  end)
end

local function detach_closed_tabs()
  local detached = {}
  for _, owner in ipairs(vim.tbl_keys(registry)) do
    if not vim.api.nvim_tabpage_is_valid(owner) then
      for _, position_groups in pairs(registry[owner]) do
        for _, group in pairs(position_groups) do
          for _, entry in ipairs(group.terminals) do
            entry.intentional_close = true
            entry.removed = true
            entry.focused_before_leave = false
            entry.attention = false
            detached[#detached + 1] = entry
          end
        end
      end
      registry[owner] = nil
      side_widths[owner] = nil
    end
  end
  for _, owner in ipairs(vim.tbl_keys(side_widths)) do
    if not vim.api.nvim_tabpage_is_valid(owner) then
      side_widths[owner] = nil
    end
  end

  if #detached == 0 then
    return
  end

  redraw_attention()
  vim.schedule(function()
    without_winleave(function()
      local first_error
      for _, entry in ipairs(detached) do
        if buf_valid(entry.terminal) then
          local ok, err = pcall(entry.terminal.close, entry.terminal)
          if not ok then
            first_error = first_error or err
          end
        end
      end
      if first_error then
        error(first_error, 0)
      end
    end)
  end)
end

vim.api.nvim_create_autocmd({ "TabNew", "DirChanged" }, {
  group = lifecycle_group,
  callback = synchronize_tab_attention,
})
vim.api.nvim_create_autocmd("TabClosed", {
  group = lifecycle_group,
  callback = detach_closed_tabs,
})
synchronize_tab_attention()

---Configure terminals created after this call.
---@param opts? terminals.Config
function M.setup(opts)
  configured_position = opts and opts.position or default_position
end

---Create a terminal, focusing it when its target group directory is applicable.
---@param cmd? string|string[]
---@param opts? terminals.NewOptions
---@return snacks.terminal
function M.new(cmd, opts)
  opts = opts or {}
  local owner, base, position, previous = applicable_scope(opts.position)
  local cwd = resolve_cwd(opts.cwd, base)
  local group_cwd = opts.group and base or cwd
  local foreground = group_cwd == base
  next_count = next_count + 1

  local terminal
  without_winleave(function()
    remember_visible_side_width(owner, position)
    if foreground then
      hide_visible(owner, position)
    end
    local win = window_options(owner, position)
    if not foreground then
      win.enter = false
    end
    terminal = snacks().terminal.open(cmd, {
      auto_close = false,
      cwd = cwd,
      count = next_count,
      env = opts.env,
      win = win,
    })
  end)
  assert(terminal, "Snacks.terminal.open() did not return a terminal")

  local group = ensure_group(owner, group_cwd, position)
  local entry = {
    owner = owner,
    group_cwd = group_cwd,
    cwd = cwd,
    position = position,
    cmd = cmd,
    terminal = terminal,
    title = opts.title,
    attention = false,
    hiding = false,
    intentional_close = false,
    removed = false,
    departure_generation = 0,
    finalization_scheduled = false,
    finalization_done = false,
    finalization_checktime = false,
    finalization_was_focused = false,
    finalization_was_visible = false,
  }
  clear_departing_state(entry)
  group.terminals[#group.terminals + 1] = entry
  group.active = #group.terminals
  attach(entry)

  without_winleave(function()
    if foreground then
      terminal:show()
      enforce_side_window(owner, position, terminal)
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
  remember_side_width(entry.owner, entry.position, entry.terminal)
  local fallback = remove_entry(entry, true)
  without_winleave(function()
    entry.terminal:close()
  end)
  focus_fallback(fallback)
  return entry.terminal
end

---@param offset integer
---@param opts? terminals.ScopeOptions
---@return snacks.terminal?
local function cycle(offset, opts)
  local owner, group_cwd, position = applicable_scope(opts and opts.position)
  local group = prune(owner, group_cwd, position)
  if not group then
    return nil
  end

  group.active = ((group.active - 1 + offset) % #group.terminals) + 1
  return focus(group.terminals[group.active])
end

---Select and focus the previous terminal for the applicable group directory and position.
---@param opts? terminals.ScopeOptions
---@return snacks.terminal?
function M.prev(opts)
  return cycle(-1, opts)
end

---Select and focus the next terminal for the applicable group directory and position.
---@param opts? terminals.ScopeOptions
---@return snacks.terminal?
function M.next(opts)
  return cycle(1, opts)
end

---Hide or show the selected terminal for the applicable group directory and position.
---@param opts? terminals.ScopeOptions
---@return snacks.terminal
function M.toggle(opts)
  local owner, group_cwd, position = applicable_scope(opts and opts.position)
  local group = prune(owner, group_cwd, position)
  if not group then
    return M.new(nil, { position = position })
  end

  local entry = group.terminals[group.active]
  if win_valid(entry.terminal) then
    remember_side_width(entry.owner, entry.position, entry.terminal)
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

  local owner = vim.api.nvim_get_current_tabpage()
  local entry
  local target_cwd
  if position then
    local open = visible_entries(owner, position)
    entry = open[1]
    if entry then
      target_cwd = entry.cwd
    else
      local _, group_cwd, resolved_position = applicable_scope(position)
      local group = prune(owner, group_cwd, resolved_position)
      entry = group and group.terminals[group.active]
      target_cwd = entry and entry.cwd or group_cwd
    end
  else
    local open = visible_entries(owner)
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
