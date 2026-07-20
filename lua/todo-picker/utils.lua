local M = {}

local config = require('todo-picker.config')

function M.today()
  return os.date(config.options.date_format)
end

function M.notify_todo(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = 'TODO' })
end

function M.get_highlight_hex(name, attr)
  local hl_id = vim.fn.hlID(name)
  if hl_id == 0 then
    return nil
  end

  local value = vim.fn.synIDattr(hl_id, attr, 'gui')
  if value == '' then
    return nil
  end

  return value
end

function M.apply_todo_status_highlights()
  for status, target in pairs(config.STATUS_COLOR) do
    local source = config.STATUS_SOURCE_HL[status]
    local spec = {
      fg = M.get_highlight_hex(source, 'fg#'),
      bg = M.get_highlight_hex(source, 'bg#'),
      sp = M.get_highlight_hex(source, 'sp#'),
      italic = false,
    }

    vim.api.nvim_set_hl(0, target, spec)
  end

  vim.api.nvim_set_hl(0, config.PARENT_HINT_HL, {
    fg = M.get_highlight_hex('NonText', 'fg#'),
    bg = M.get_highlight_hex('NonText', 'bg#'),
    sp = M.get_highlight_hex('NonText', 'sp#'),
    italic = false,
  })

  vim.api.nvim_set_hl(0, config.TAG_HEADER_HL, {
    link = 'SnacksPickerKeymapLhs',
  })

  vim.api.nvim_set_hl(0, "TodoBoardActiveBorder", {
    fg = "Yellow",
    bold = true,
  })

  vim.api.nvim_set_hl(0, "TodoTransparentBorder", {
    fg = M.get_highlight_hex("Comment", "fg#") or M.get_highlight_hex("NonText", "fg#"),
    bg = "NONE",
  })

  vim.api.nvim_set_hl(0, "TodoFloatTitle", {
    fg = M.get_highlight_hex("SnacksPickerKeymapLhs", "fg#") or M.get_highlight_hex("Title", "fg#") or "#bb9af7",
    bold = true,
  })

  vim.api.nvim_set_hl(0, "SnacksPickerBorder", { link = "TodoTransparentBorder" })
  vim.api.nvim_set_hl(0, "SnacksPicker", { link = "Normal" })
  vim.api.nvim_set_hl(0, "SnacksPickerInput", { link = "Normal" })
  vim.api.nvim_set_hl(0, "SnacksPickerList", { link = "Normal" })
  vim.api.nvim_set_hl(0, "SnacksPickerPreview", { link = "Normal" })

  vim.api.nvim_set_hl(0, config.TITLE_HL_BLOCKED, {
    fg = M.get_highlight_hex('DiagnosticError', 'fg#'),
    bg = M.get_highlight_hex('DiagnosticError', 'bg#'),
    sp = M.get_highlight_hex('DiagnosticError', 'sp#'),
    italic = false,
  })

  vim.api.nvim_set_hl(0, config.TITLE_HL_PEER_REVIEW, {
    fg = M.get_highlight_hex('Directory', 'fg#') or M.get_highlight_hex('DiagnosticInfo', 'fg#'),
    bg = M.get_highlight_hex('Directory', 'bg#') or M.get_highlight_hex('DiagnosticInfo', 'bg#'),
    sp = M.get_highlight_hex('Directory', 'sp#') or M.get_highlight_hex('DiagnosticInfo', 'sp#'),
    italic = false,
  })

  local group = vim.api.nvim_create_augroup("todo_picker_colors", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      pcall(M.apply_todo_status_highlights)
    end,
  })
end

function M.title_highlight_for_status(status, fallback)
  if status == config.STATUS_BLOCKED then
    return config.TITLE_HL_BLOCKED
  end
  if status == config.STATUS_PEER_REVIEW then
    return config.TITLE_HL_PEER_REVIEW
  end
  return fallback or 'Normal'
end

function M.is_valid_date(date_str)
  if not date_str then return false end
  local yy, mm, dd = date_str:match('^(%d%d)/(%d%d)/(%d%d)$')
  if not yy then return false end
  local month = tonumber(mm)
  local day = tonumber(dd)
  return month ~= nil and day ~= nil and month >= 1 and month <= 12 and day >= 1 and day <= 31
end

function M.parse_date_to_sortkey(date_str)
  if not M.is_valid_date(date_str) then return -1 end
  local yy, mm, dd = date_str:match('^(%d%d)/(%d%d)/(%d%d)$')
  local year = 2000 + tonumber(yy)
  local month = tonumber(mm)
  local day = tonumber(dd)
  return (year % 100) * 10000 + month * 100 + day
end

function M.parse_date_to_time(date_str)
  if not M.is_valid_date(date_str) then return nil end
  local yy, mm, dd = date_str:match('^(%d%d)/(%d%d)/(%d%d)$')
  return os.time {
    year = 2000 + tonumber(yy),
    month = tonumber(mm),
    day = tonumber(dd),
    hour = 0,
    min = 0,
    sec = 0,
  }
end

function M.parse_log_entry(line)
  if type(line) ~= 'string' then
    return nil, nil
  end

  local trimmed = vim.trim(line)
  if trimmed == '' then
    return nil, nil
  end

  local date_str, text = trimmed:match('^%[?(%d%d/%d%d/%d%d)%]?%s*[-:]%s*(.+)$')
  if date_str and M.is_valid_date(date_str) then
    local message = vim.trim(text or '')
    if message ~= '' then
      return date_str, message
    end
  end

  return nil, trimmed
end

function M.format_log_entry(date_str, message)
  return string.format('%s - %s', date_str, vim.trim(message or ''))
end

function M.normalize_log_entries(lines, fallback_date)
  local normalized = {}
  local default_date = M.is_valid_date(fallback_date) and fallback_date or M.today()

  for _, line in ipairs(lines or {}) do
    local date_str, message = M.parse_log_entry(tostring(line or ''))
    if message and message ~= '' then
      normalized[#normalized + 1] = M.format_log_entry(date_str or default_date, message)
    end
  end

  return normalized
end

function M.is_valid_todo_id(value)
  return type(value) == 'string' and value:match('^[-_%w]+$') ~= nil
end

function M.get_todo_store_path()
  return vim.fs.normalize(vim.fn.getcwd() .. '/' .. config.options.todo_json_name)
end

function M.read_file_lines(file)
  local handle = io.open(file, 'r')
  if not handle then
    return nil
  end
  local lines = {}
  for line in handle:lines() do
    lines[#lines + 1] = line
  end
  handle:close()
  return lines
end

function M.write_text_file(file, text)
  local tmp_file = file .. '.tmp'
  local handle = io.open(tmp_file, 'w')
  if not handle then
    return false
  end
  local ok, err = pcall(function()
    handle:write(text)
  end)
  handle:close()
  if not ok then
    os.remove(tmp_file)
    return false
  end
  local renamed, rename_err = os.rename(tmp_file, file)
  if not renamed then
    os.remove(tmp_file)
    return false
  end
  return true
end

function M.get_loaded_bufnr(file)
  if not file or file == '' then
    return nil
  end
  local bufnr = vim.fn.bufnr(file, true)
  vim.fn.bufload(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  return bufnr
end

function M.maybe_write_buffer(bufnr)
  if not bufnr then
    return
  end
  if vim.bo[bufnr].buftype ~= '' or not vim.bo[bufnr].modifiable or vim.bo[bufnr].readonly then
    return
  end
  pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd 'silent noautocmd write'
  end)
end

function M.open_source_at(file, lnum)
  if not file or not lnum then
    return
  end
  vim.schedule(function()
    vim.cmd('edit ' .. vim.fn.fnameescape(file))
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    vim.cmd 'normal! zz'
  end)
end

return M
