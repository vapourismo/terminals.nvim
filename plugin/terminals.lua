if vim.g.loaded_terminals_nvim then
  return
end
vim.g.loaded_terminals_nvim = true

vim.api.nvim_create_user_command("TermNew", function(options)
  require("terminals").new(options.args ~= "" and options.args or nil)
end, {
  nargs = "*",
  complete = "shellcmd",
  desc = "Create a floating terminal",
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
