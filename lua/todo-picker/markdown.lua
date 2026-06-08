local M = {}

local config = require('todo-picker.config')
local utils = require('todo-picker.utils')
local store = require('todo-picker.store')

M.TODO_REF_PATTERN = '^%s*TODO:%s*(.-)%s*%(%#([-%w_]+)%)%s*$'

function M.parse_reference_line(line)
  local title, todo_id = (line or ''):match(M.TODO_REF_PATTERN)
  if not title or not todo_id then
    return nil
  end
  return {
    title = vim.trim(title),
    todo_id = todo_id,
  }
end

function M.build_reference_line(title, todo_id)
  return string.format('TODO: %s (#%s)', vim.trim(title or ''), todo_id or '')
end

function M.find_reference_lnum_in_file(file, todo_id)
  local bufnr = utils.get_loaded_bufnr(file)
  local lines
  if bufnr then
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  else
    lines = utils.read_file_lines(file)
  end
  if not lines then
    return nil
  end
  for lnum, line in ipairs(lines) do
    local parsed = M.parse_reference_line(line)
    if parsed and parsed.todo_id == todo_id then
      return lnum
    end
  end
  return nil
end

function M.resolve_reference(todo, store_obj)
  if not todo or not todo.id then
    return nil, nil
  end

  local file = todo.reference and todo.reference.file
  local lnum = todo.reference and todo.reference.lnum

  if file and lnum then
    local bufnr = utils.get_loaded_bufnr(file)
    if bufnr and lnum >= 1 and lnum <= vim.api.nvim_buf_line_count(bufnr) then
      local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ''
      local parsed = M.parse_reference_line(line)
      if parsed and parsed.todo_id == todo.id then
        return file, lnum
      end
    end
  end

  if not file or file == '' then
    return nil, nil
  end

  local found = M.find_reference_lnum_in_file(file, todo.id)
  if not found then
    return nil, nil
  end

  todo.reference = todo.reference or {}
  todo.reference.file = file
  todo.reference.lnum = found
  store.write_store(store_obj)
  return file, found
end

function M.update_reference_line_for_todo(todo, store_obj)
  if not todo or not todo.id or not todo.reference or not todo.reference.file then
    return
  end

  local file, lnum = M.resolve_reference(todo, store_obj)
  if not file or not lnum then
    return
  end

  local bufnr = utils.get_loaded_bufnr(file)
  if not bufnr then
    return
  end

  local desired = M.build_reference_line(todo.title, todo.id)
  local current = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ''
  if current == desired then
    return
  end

  vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { desired })
  utils.maybe_write_buffer(bufnr)
end

function M.adjust_reference_lines_after_insert(store_obj, file, at_lnum, delta, exclude_todo_id)
  if not file or not at_lnum or delta == 0 then
    return
  end

  for _, todo in ipairs(store_obj.todos or {}) do
    if todo.id ~= exclude_todo_id and todo.reference and todo.reference.file == file and todo.reference.lnum and todo.reference.lnum >= at_lnum then
      todo.reference.lnum = todo.reference.lnum + delta
    end
  end
end

function M.find_todo_id_lnum_in_store(file, todo_id)
  local bufnr = utils.get_loaded_bufnr(file)
  local lines
  if bufnr then
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  else
    lines = utils.read_file_lines(file)
  end
  if not lines then
    return nil
  end

  local id_pattern = '"id"%s*:%s*"' .. vim.pesc(todo_id or '') .. '"'
  for lnum, line in ipairs(lines) do
    if line:match(id_pattern) then
      return lnum
    end
  end

  return nil
end

function M.resolve_source(todo)
  if not todo or not todo.id then
    return nil, nil
  end

  local file = (todo.source and todo.source.file) or utils.get_todo_store_path()
  local lnum = todo.source and todo.source.lnum or nil

  if not lnum then
    lnum = M.find_todo_id_lnum_in_store(file, todo.id)
  end

  return file, lnum
end

function M.create_reference_at_line(bufnr, lnum, line_text, insert_only)
  if insert_only then
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum - 1, false, { line_text })
    return lnum
  end
  vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { line_text })
  return lnum
end

function M.get_line(bufnr, lnum)
  return vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ''
end

function M.is_blank_line(line)
  return line:match('^%s*$') ~= nil
end

function M.is_quote_line(line)
  return line:match('^%s*>') ~= nil
end

function M.find_next_non_quote_line(bufnr, lnum)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local idx = lnum
  while idx <= line_count and M.is_quote_line(M.get_line(bufnr, idx)) do
    idx = idx + 1
  end
  return idx
end

function M.build_item_for_cursor_reference(bufnr, lnum)
  local line = M.get_line(bufnr, lnum)
  local parsed_ref = M.parse_reference_line(line)
  if not parsed_ref then
    local title, todo_id = line:match('TODO:%s*(.-)%s*%(%#([-%w_]+)%)')
    if title and todo_id then
      parsed_ref = {
        title = vim.trim(title),
        todo_id = todo_id,
      }
    end
  end
  if not parsed_ref then
    return nil
  end

  local store_obj = store.load_store()
  local idx = store.find_todo_bucket(store_obj, parsed_ref.todo_id)
  if not idx then
    return nil
  end

  idx.todo.reference = idx.todo.reference or {}
  idx.todo.reference.file = vim.api.nvim_buf_get_name(bufnr)
  idx.todo.reference.lnum = lnum
  store.write_store(store_obj)

  return store.build_item_from_todo(idx.todo)
end

function M.open_markdown_todo_draft(bufnr, lnum, insert_only)
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == '' then
    utils.notify_todo('Buffer has no associated file', vim.log.levels.ERROR)
    return
  end

  local ui = require('todo-picker.ui')
  ui.open_new_todo_draft(nil, nil, {
    title = '',
    parent_id = nil,
    create_reference = true,
    reference = {
      file = file,
      lnum = lnum,
      insert_only = insert_only == true,
    },
  })
end

function M.open_markdown_todo_draft_at_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local current_line = M.get_line(bufnr, lnum)

  if M.is_quote_line(current_line) then
    local target = M.find_next_non_quote_line(bufnr, lnum)
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if target > line_count then
      M.open_markdown_todo_draft(bufnr, target, true)
      return
    end
    if M.is_blank_line(M.get_line(bufnr, target)) then
      M.open_markdown_todo_draft(bufnr, target, false)
    else
      M.open_markdown_todo_draft(bufnr, target, true)
    end
    return
  end

  if M.is_blank_line(current_line) then
    M.open_markdown_todo_draft(bufnr, lnum, false)
    return
  end

  local target = lnum + 1
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if target > line_count then
    M.open_markdown_todo_draft(bufnr, target, true)
  elseif M.is_blank_line(M.get_line(bufnr, target)) then
    M.open_markdown_todo_draft(bufnr, target, false)
  else
    M.open_markdown_todo_draft(bufnr, target, true)
  end
end

function M.setup_todo_keymaps()
  local bufnr = 0
  vim.keymap.set('n', '<leader>mt', function()
    vim.cmd 'TodoReference'
  end, { buffer = bufnr, desc = 'todo reference / new todo' })
end

function M.get_cursor_reference_item()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]
  return M.build_item_for_cursor_reference(bufnr, cursor_lnum)
end

function M.insert_todo_reference_at_cursor(todo_id, todo_title)
  local bufnr = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == '' then
    utils.notify_todo('Buffer has no associated file', vim.log.levels.ERROR)
    return false
  end

  local store_obj = store.load_store()
  local idx = store.find_todo_bucket(store_obj, todo_id)
  if not idx then
    utils.notify_todo('Todo not found in store', vim.log.levels.WARN)
    return false
  end

  local existing_ref_file, existing_ref_lnum = M.resolve_reference(idx.todo, store_obj)
  if existing_ref_file and existing_ref_lnum then
    local rel = vim.fn.fnamemodify(existing_ref_file, ':~:.')
    local display = (rel ~= '' and rel or existing_ref_file) .. ':' .. tostring(existing_ref_lnum)
    local confirmed = vim.fn.confirm(
      'This todo already has a reference at\n\n' .. display .. '\n\nMove it to the current cursor location?',
      '&Yes\n&No',
      2
    ) == 1
    if not confirmed then
      return false
    end
  end

  local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]

  if existing_ref_file and existing_ref_lnum then
    local ref_buf = utils.get_loaded_bufnr(existing_ref_file)
    if not ref_buf then
      utils.notify_todo('Could not open existing reference buffer', vim.log.levels.WARN)
      return false
    end

    local line = vim.api.nvim_buf_get_lines(ref_buf, existing_ref_lnum - 1, existing_ref_lnum, false)[1] or ''
    local parsed = M.parse_reference_line(line)
    if not parsed or parsed.todo_id ~= todo_id then
      utils.notify_todo('Could not verify existing reference line', vim.log.levels.WARN)
      return false
    end

    vim.api.nvim_buf_set_lines(ref_buf, existing_ref_lnum - 1, existing_ref_lnum, false, {})
    utils.maybe_write_buffer(ref_buf)
    M.adjust_reference_lines_after_insert(store_obj, existing_ref_file, existing_ref_lnum + 1, -1, todo_id)

    if existing_ref_file == file and existing_ref_lnum < cursor_lnum then
      cursor_lnum = math.max(1, cursor_lnum - 1)
    end
  end
  local cursor_line = M.get_line(bufnr, cursor_lnum)
  local insert_only = not M.is_blank_line(cursor_line)
  local target_lnum = insert_only and (cursor_lnum + 1) or cursor_lnum
  local line_text = M.build_reference_line(todo_title or idx.todo.title or '', todo_id)
  local inserted_lnum = M.create_reference_at_line(bufnr, target_lnum, line_text, insert_only)

  idx.todo.reference = idx.todo.reference or {}
  idx.todo.reference.file = file
  idx.todo.reference.lnum = inserted_lnum
  store.ensure_todo_source(idx.todo)

  M.adjust_reference_lines_after_insert(
    store_obj,
    file,
    inserted_lnum + (insert_only and 1 or 0),
    insert_only and 1 or 0,
    todo_id
  )
  utils.maybe_write_buffer(bufnr)

  if not store.write_store(store_obj) then
    return false
  end

  return true
end

function M.run_todo_reference_picker()
  if vim.bo.filetype ~= 'markdown' then
    utils.notify_todo('TodoReference works in markdown buffers', vim.log.levels.WARN)
    return
  end

  local picker = require('todo-picker.picker')
  local opts = picker.get_todo_picker_opts {
    title = 'Select TODO To Reference',
    apply_done_retention = false,
  }

  opts.confirm = function(p, item)
    local target = picker.picker_current_item(p, item) or item
    if not target then
      return
    end

    if p and p.close then
      p:close()
    end

    if target.todo_is_empty_state then
      M.open_markdown_todo_draft_at_cursor(vim.api.nvim_get_current_buf())
      return
    end

    if not target.todo_id then
      return
    end

    local ok = M.insert_todo_reference_at_cursor(target.todo_id, target.todo_text or target.text)
    if ok then
      utils.notify_todo('Inserted TODO reference')
    end
  end

  Snacks.picker(opts)
end

return M
