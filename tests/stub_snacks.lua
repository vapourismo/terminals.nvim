local M = {
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

function Terminal:_attach_win_events()
  if self.win_group then
    pcall(vim.api.nvim_del_augroup_by_id, self.win_group)
  end
  self.win_group = vim.api.nvim_create_augroup("terminals_test_win_" .. self.id, { clear = true })
  for _, handler in ipairs(self.win_events) do
    vim.api.nvim_create_autocmd(handler.event, {
      group = self.win_group,
      pattern = tostring(self.win),
      callback = function(event)
        return handler.callback(self, event)
      end,
    })
  end
end

function Terminal:show()
  self.show_count = self.show_count + 1
  if self:win_valid() then
    return self
  end
  local width = math.max(1, math.min(self.opts.win.width or 40, vim.o.columns - 2))
  self.win = vim.api.nvim_open_win(self.buf, false, {
    relative = "editor",
    row = 1,
    col = 1,
    width = width,
    height = 4,
    style = "minimal",
  })
  self:_attach_win_events()
  return self
end

function Terminal:hide()
  self.hide_count = self.hide_count + 1
  local win = self.win
  self.win = nil
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
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
  self:hide()
  if self:buf_valid() then
    vim.api.nvim_buf_delete(self.buf, { force = true })
  end
  return self
end

function Terminal:on(event, callback, opts)
  opts = opts or {}
  if opts.win then
    self.win_events[#self.win_events + 1] = { event = event, callback = callback }
    if self:win_valid() then
      self:_attach_win_events()
    end
    return
  end

  vim.api.nvim_create_autocmd(event, {
    group = self.buf_group,
    buffer = opts.buf and self.buf or nil,
    callback = function(event_args)
      return callback(self, event_args)
    end,
  })
end

function M.reset()
  for _, terminal in ipairs(M.opened) do
    if terminal:buf_valid() then
      terminal:close()
    end
  end
  M.opened = {}
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
    win_events = {},
    hide_count = 0,
    show_count = 0,
    focus_count = 0,
    close_count = 0,
  }, Terminal)
  terminal.buf_group = vim.api.nvim_create_augroup("terminals_test_buf_" .. terminal.id, { clear = true })
  terminal:show()
  M.opened[#M.opened + 1] = terminal
  return terminal
end

return M
