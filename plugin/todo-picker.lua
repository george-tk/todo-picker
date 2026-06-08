if vim.g.loaded_todo_picker then
  return
end
vim.g.loaded_todo_picker = true

vim.api.nvim_create_user_command('Todo', function()
  require('todo-picker').open()
end, { desc = 'Open TODO Picker' })

vim.api.nvim_create_user_command('TodoPicker', function()
  require('todo-picker').open()
end, { desc = 'Open TODO Picker' })

vim.api.nvim_create_user_command('TodoFilter', function(cmd)
  require('todo-picker').filter(cmd.args)
end, {
  nargs = '*',
  desc = 'Show TODOs filtered by metadata fields or labels',
})

vim.api.nvim_create_user_command('TodoGoTo', function()
  require('todo-picker').goto_todo()
end, { desc = 'Open details for the TODO under cursor' })

vim.api.nvim_create_user_command('TodoReference', function()
  require('todo-picker').reference()
end, { desc = 'Insert a TODO reference in markdown via picker selection' })

local group = vim.api.nvim_create_augroup('TodoPickerPlugin', { clear = true })
local defaults = require('todo-picker.config').defaults

vim.api.nvim_create_autocmd('FileType', {
  group = group,
  pattern = defaults.filetypes,
  callback = function()
    require('todo-picker.markdown').setup_todo_keymaps()
  end,
})

vim.api.nvim_create_autocmd('ColorScheme', {
  group = group,
  callback = function()
    require('todo-picker.utils').apply_todo_status_highlights()
  end,
})
