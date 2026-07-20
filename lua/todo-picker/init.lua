local M = {}

function M.setup(opts)
  require('todo-picker.config').setup(opts)
  require('todo-picker.utils').apply_todo_status_highlights()

  -- Re-register autocmds in case filetypes changed
  local group = vim.api.nvim_create_augroup('TodoPickerPlugin', { clear = true })
  local config = require('todo-picker.config').options

  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = config.filetypes,
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
end

function M.open(opts)
  return require('todo-picker.picker').open_todo_picker(opts)
end

function M.new_todo()
  require('todo-picker.ui').open_new_todo_draft(nil, nil, {
    title = "",
    status = require('todo-picker.config').defaults.STATUS_TODO or "todo",
    priority = require('todo-picker.config').defaults.PRIORITY_LOW or "low",
    labels = {},
  })
end

function M.new_todo_reference()
  if vim.bo.filetype ~= 'markdown' then
    require('todo-picker.utils').notify_todo('TodoNewReference works in markdown buffers', vim.log.levels.WARN)
    return
  end
  require('todo-picker.markdown').open_markdown_todo_draft_at_cursor()
end

function M.goto_todo()
  local item = require('todo-picker.markdown').get_cursor_reference_item()
  if not item then
    require('todo-picker.utils').notify_todo('Cursor is not on a TODO reference line', vim.log.levels.WARN)
    return
  end
  require('todo-picker.ui').open_todo_detail(nil, item, { start_zone = 'log', start_insert = false })
end

function M.reference()
  require('todo-picker.markdown').run_todo_reference_picker()
end

function M.kanban(opts)
  require('todo-picker.kanban').open_kanban(opts)
end

function M.work_log(range_arg)
  require('todo-picker.log').open_work_log(range_arg)
end

return M
