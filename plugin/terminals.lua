if vim.g.loaded_terminals_nvim then
  return
end
vim.g.loaded_terminals_nvim = true

vim.api.nvim_create_user_command("TermNew", function(options)
  require("terminals").new(options.args ~= "" and options.args or nil)
end, {
  nargs = "*",
  complete = "shellcmd",
  desc = "Create a managed terminal",
})

local function terminal_command(name, method, description)
  vim.api.nvim_create_user_command(name, function()
    require("terminals")[method]()
  end, { desc = description })
end

terminal_command("TermClose", "close", "Destroy the focused managed terminal")
terminal_command("TermPrev", "prev", "Select the previous terminal")
terminal_command("TermNext", "next", "Select the next terminal")
terminal_command("TermToggle", "toggle", "Toggle the selected terminal")

local positions = { "float", "top", "bottom", "left", "right" }

local function complete_position(arg_lead)
  return vim.tbl_filter(function(position)
    return position:sub(1, #arg_lead) == arg_lead
  end, positions)
end

vim.api.nvim_create_user_command("TermMove", function(options)
  require("terminals").move({ position = options.args })
end, {
  nargs = 1,
  complete = complete_position,
  desc = "Move the focused managed terminal to another position",
})

vim.api.nvim_create_user_command("TermSend", function(options)
  require("terminals").send({
    position = options.args ~= "" and options.args or nil,
    _command = options,
  })
end, {
  nargs = "?",
  range = true,
  complete = complete_position,
  desc = "Insert the Visual selection location into a managed terminal",
})
