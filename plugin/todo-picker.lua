if vim.g.loaded_todo_picker then
  return
end
vim.g.loaded_todo_picker = true

vim.api.nvim_create_user_command('TodoList', function()
  require('todo-picker').open()
end, { desc = 'Open TODO List' })

vim.api.nvim_create_user_command('TodoBoard', function()
  require('todo-picker.kanban').open_kanban()
end, { desc = 'Open TODO Board' })

vim.api.nvim_create_user_command('TodoNew', function()
  require('todo-picker').new_todo()
end, { desc = 'Create a new TODO ticket' })

vim.api.nvim_create_user_command('TodoLinkNew', function()
  require('todo-picker').new_todo_reference()
end, { desc = 'Create a new TODO ticket and reference it at the cursor line' })

vim.api.nvim_create_user_command('TodoLink', function()
  require('todo-picker').reference()
end, { desc = 'Insert a TODO reference in markdown via picker selection' })

vim.api.nvim_create_user_command('TodoJump', function()
  require('todo-picker').goto_todo()
end, { desc = 'Open details for the TODO under cursor' })

vim.api.nvim_create_user_command('TodoLog', function(opts)
  require('todo-picker.log').open_work_log(opts.args)
end, {
  nargs = '?',
  complete = function()
    return { 'today', 'week', 'month', '3', '7', '14', '30' }
  end,
  desc = 'Generate and view Work Activity Log (e.g. :TodoLog today, :TodoLog week)',
})


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
