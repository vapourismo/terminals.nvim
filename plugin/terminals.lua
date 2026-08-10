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

vim.api.nvim_create_user_command("TermClose", function()
  require("terminals").close()
end, { desc = "Destroy the focused managed terminal" })

vim.api.nvim_create_user_command("TermPrev", function()
  require("terminals").prev()
end, { desc = "Select the previous terminal" })

vim.api.nvim_create_user_command("TermNext", function()
  require("terminals").next()
end, { desc = "Select the next terminal" })

vim.api.nvim_create_user_command("TermToggle", function()
  require("terminals").toggle()
end, { desc = "Toggle the selected terminal" })

local positions = { "float", "top", "bottom", "left", "right" }

vim.api.nvim_create_user_command("TermSend", function(options)
  require("terminals").send({
    position = options.args ~= "" and options.args or nil,
    _command = options,
  })
end, {
  nargs = "?",
  range = true,
  complete = function(arg_lead)
    return vim.tbl_filter(function(position)
      return position:sub(1, #arg_lead) == arg_lead
    end, positions)
  end,
  desc = "Insert the Visual selection location into a managed terminal",
})
