local M = {
  notifications = {},
  notification_calls = {},
  opened = {},
}

local Terminal = {}
Terminal.__index = Terminal

local next_id = 0

function Terminal:buf_valid()
  return self.buf and vim.api.nvim_buf_is_valid(self.buf) or false
end

function Terminal:win_valid()
  return self.win and vim.api.nvim_win_is_valid(self.win) or false
end

function Terminal:_create_autocmd(handler)
  local opts = handler.opts
  local autocmd_opts = {
    group = self.augroup,
    callback = function(event)
      return handler.callback(self, event)
    end,
  }
  if opts.win then
    autocmd_opts.pattern = tostring(self.win)
  elseif opts.buf then
    autocmd_opts.buffer = self.buf
  end
  vim.api.nvim_create_autocmd(handler.event, autocmd_opts)
end

function Terminal:_attach_events()
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  end
  self.augroup = vim.api.nvim_create_augroup("terminals_test_snacks_" .. self.id, { clear = true })
  for _, handler in ipairs(self.events) do
    self:_create_autocmd(handler)
  end
end

function Terminal:show()
  self.show_count = self.show_count + 1
  if self:win_valid() then
    return self
  end
  local width = math.max(1, math.min(self.opts.win.width or 40, vim.o.columns - 2))
  local win = vim.api.nvim_open_win(self.buf, self.opts.win.enter ~= false, {
    relative = "editor",
    row = 1,
    col = 1,
    width = width,
    height = 4,
    style = "minimal",
  })
  self.win = win
  for option, value in pairs(self.opts.win.wo or {}) do
    vim.api.nvim_set_option_value(option, value, { win = self.win })
  end
  self:_attach_events()
  return self
end

function Terminal:hide()
  self.hide_count = self.hide_count + 1
  local win = self.win
  self.win = nil
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
  return self
end

function Terminal:focus()
  self.focus_count = self.focus_count + 1
  if self:win_valid() then
    vim.api.nvim_set_current_win(self.win)
  end
  return self
end

function Terminal:close()
  self.close_count = self.close_count + 1
  if self.process_running then
    self.process_running = false
    vim.api.nvim_exec_autocmds("TermClose", {
      buffer = self.buf,
      data = { status = 129 },
    })
  end
  self:hide()
  if self:buf_valid() then
    vim.api.nvim_buf_delete(self.buf, { force = true })
  end
  return self
end

function Terminal:exit(status)
  if not self.process_running then
    return self
  end
  self.process_running = false
  vim.api.nvim_exec_autocmds("TermClose", {
    buffer = self.buf,
    data = { status = status },
  })
  return self
end

function Terminal:request(sequence)
  vim.api.nvim_exec_autocmds("TermRequest", {
    buffer = self.buf,
    data = {
      sequence = sequence,
      terminator = "\7",
      cursor = { 1, 0 },
    },
  })
  return self
end

function Terminal:on(event, callback, opts)
  opts = opts or {}
  local handler = { event = event, callback = callback, opts = opts }
  self.events[#self.events + 1] = handler
  if self:win_valid() then
    self:_create_autocmd(handler)
  end
end

function M.reset()
  for _, terminal in ipairs(M.opened) do
    if terminal:buf_valid() then
      terminal.process_running = false
      terminal:close()
    end
  end
  M.notifications = {}
  M.notification_calls = {}
  M.opened = {}
end

M.notify = {}

local function notify(message, level, opts)
  M.notifications[#M.notifications + 1] = message
  M.notification_calls[#M.notification_calls + 1] = {
    message = message,
    level = level,
    opts = opts,
  }
end

function M.notify.error(message, opts)
  notify(message, vim.log.levels.ERROR, opts)
end

function M.notify.info(message, opts)
  notify(message, vim.log.levels.INFO, opts)
end

M.terminal = {}

function M.terminal.open(cmd, opts)
  next_id = next_id + 1
  local terminal = setmetatable({
    id = next_id,
    cmd = cmd,
    opts = opts,
    buf = vim.api.nvim_create_buf(false, true),
    win = nil,
    events = {},
    hide_count = 0,
    show_count = 0,
    focus_count = 0,
    close_count = 0,
    process_running = true,
  }, Terminal)
  terminal:show()
  M.opened[#M.opened + 1] = terminal
  return terminal
end

return M
