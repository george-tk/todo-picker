local M = {}

local config = require('todo-picker.config')
local utils = require('todo-picker.utils')

M.CORE_FIELDS = {
  item = true,
  status = true,
  priority = true,
  created = true,
  completed = true,
  id = true,
  parent = true,
  description = true,
  log = true,
  labels = true,
}

local random_seeded = false

function M.default_store()
  return {
    version = 1,
    todos = {},
  }
end

function M.normalize_extra_fields(extra_fields)
  local out = {}
  for _, field in ipairs(extra_fields or {}) do
    local name = field.name and tostring(field.name):lower() or ''
    local value = field.value and tostring(field.value) or ''
    if name ~= '' and not M.CORE_FIELDS[name] then
      out[#out + 1] = { name = name, value = vim.trim(value:gsub('%s+', ' ')) }
    end
  end
  return out
end

function M.normalize_labels(labels)
  if type(labels) == 'string' then
    labels = vim.split(labels, ',', { trimempty = true })
  end

  local out = {}
  local seen = {}

  for _, raw in ipairs(labels or {}) do
    local label = vim.trim(tostring(raw or '')):lower()
    if label ~= '' and not seen[label] then
      out[#out + 1] = label
      seen[label] = true
    end
  end

  return out
end

function M.normalize_todo(todo)
  local t = vim.deepcopy(todo or {})

  if not utils.is_valid_todo_id(t.id) then
    t.id = nil
  end
  t.title = vim.trim(t.title or '')

  local status = (t.status or config.STATUS_TODO):upper()
  if not config.STATUS_SORT[status] then
    status = config.STATUS_TODO
  end

  local normalized_labels = M.normalize_labels(t.labels)

  t.status = status

  local priority = (t.priority or config.PRIORITY_LOW):upper()
  if not config.PRIORITY_SORT[priority] then
    priority = config.PRIORITY_LOW
  end
  t.priority = priority

  t.created = utils.is_valid_date(t.created) and t.created or utils.today()
  if t.status == config.STATUS_DONE and utils.is_valid_date(t.completed) then
    t.completed = t.completed
  else
    t.completed = nil
  end

  if not utils.is_valid_todo_id(t.parent_id) or t.parent_id == t.id then
    t.parent_id = nil
  end

  t.extra_fields = M.normalize_extra_fields(t.extra_fields)
  t.labels = normalized_labels

  t.description = vim.trim(t.description and tostring(t.description) or '')

  local raw_log = type(t.log) == 'table' and t.log or t.details
  t.log = utils.normalize_log_entries(raw_log or {}, t.created)
  t.details = vim.deepcopy(t.log)

  if type(t.source) ~= 'table' then
    t.source = {}
  end
  t.source.file = t.source.file and vim.fs.normalize(t.source.file) or nil
  t.source.lnum = tonumber(t.source.lnum) or nil
  t.source.todo_id = utils.is_valid_todo_id(t.source.todo_id) and t.source.todo_id or nil

  if type(t.reference) ~= 'table' then
    t.reference = {}
  end
  t.reference.file = t.reference.file and vim.fs.normalize(t.reference.file) or nil
  t.reference.lnum = tonumber(t.reference.lnum) or nil

  return t
end

function M.ensure_todo_source(todo)
  if type(todo) ~= 'table' then
    return
  end

  todo.source = type(todo.source) == 'table' and todo.source or {}
  todo.source.file = utils.get_todo_store_path()
  todo.source.todo_id = todo.id
  if not todo.source.lnum then
    todo.source.lnum = nil
  end
end

function M.is_json_array_table(tbl)
  if type(tbl) ~= 'table' then
    return false
  end

  local count = 0
  local max_index = 0
  for key, _ in pairs(tbl) do
    if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then
      return false
    end
    count = count + 1
    if key > max_index then
      max_index = key
    end
  end

  return max_index == count
end

function M.encode_json_pretty(value, level)
  level = level or 0
  local indent = string.rep('  ', level)
  local child_indent = string.rep('  ', level + 1)
  local value_type = type(value)

  if value_type ~= 'table' then
    return vim.fn.json_encode(value)
  end

  if M.is_json_array_table(value) then
    if #value == 0 then
      return '[]'
    end

    local lines = { '[' }
    for i, item in ipairs(value) do
      local suffix = (i < #value) and ',' or ''
      lines[#lines + 1] = child_indent .. M.encode_json_pretty(item, level + 1) .. suffix
    end
    lines[#lines + 1] = indent .. ']'
    return table.concat(lines, '\n')
  end

  local keys = {}
  for key, _ in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)

  if #keys == 0 then
    return '{}'
  end

  local lines = { '{' }
  for i, key in ipairs(keys) do
    local encoded_key = vim.fn.json_encode(tostring(key))
    local encoded_value = M.encode_json_pretty(value[key], level + 1)
    local suffix = (i < #keys) and ',' or ''
    lines[#lines + 1] = string.format('%s%s: %s%s', child_indent, encoded_key, encoded_value, suffix)
  end
  lines[#lines + 1] = indent .. '}'
  return table.concat(lines, '\n')
end

local cached_store = nil
local last_file_mtime = nil

function M.write_store(store)
  local store_path = utils.get_todo_store_path()
  local ok, encoded = pcall(M.encode_json_pretty, store)
  if not ok or type(encoded) ~= 'string' then
    utils.notify_todo('Could not encode todo store', vim.log.levels.ERROR)
    return false
  end
  if not utils.write_text_file(store_path, encoded) then
    utils.notify_todo('Could not write ' .. config.options.todo_json_name, vim.log.levels.ERROR)
    return false
  end

  cached_store = store
  local uv = vim.loop or vim.uv
  local stat = uv.fs_stat(store_path)
  last_file_mtime = stat and stat.mtime.sec or 0

  return true
end

function M.load_store()
  local store_path = utils.get_todo_store_path()
  local uv = vim.loop or vim.uv
  local stat = uv.fs_stat(store_path)
  local current_mtime = stat and stat.mtime.sec or 0

  if cached_store and last_file_mtime == current_mtime then
    return cached_store
  end

  local lines = utils.read_file_lines(store_path)

  if not lines then
    local created = M.default_store()
    M.write_store(created)
    cached_store = created
    local stat_new = uv.fs_stat(store_path)
    last_file_mtime = stat_new and stat_new.mtime.sec or 0
    return created
  end

  local raw = table.concat(lines, '\n')
  local ok, decoded = pcall(vim.fn.json_decode, raw)
  if not ok or type(decoded) ~= 'table' then
    utils.notify_todo('Invalid todo.json; resetting store', vim.log.levels.WARN)
    local reset = M.default_store()
    M.write_store(reset)
    cached_store = reset
    local stat_new = uv.fs_stat(store_path)
    last_file_mtime = stat_new and stat_new.mtime.sec or 0
    return reset
  end

  local store = {
    version = tonumber(decoded.version) or 1,
    todos = {},
  }

  for _, todo in ipairs(decoded.todos or {}) do
    local normalized = M.normalize_todo(todo)
    if normalized.id and normalized.title ~= '' then
      store.todos[#store.todos + 1] = normalized
    end
  end

  cached_store = store
  last_file_mtime = current_mtime
  return store
end

function M.get_todo_index(store)
  local by_id = {}
  for idx, todo in ipairs(store.todos or {}) do
    if todo.id then
      by_id[todo.id] = { todo = todo, idx = idx }
    end
  end
  return by_id
end

function M.with_todo_store(mutator)
  local store = M.load_store()
  if not store then
    return nil
  end

  local result = mutator(store, M.get_todo_index(store))
  if result == false then
    return nil
  end

  if not M.write_store(store) then
    return nil
  end

  return result, store
end

function M.find_todo_bucket(store, todo_id)
  if not store or not todo_id then
    return nil
  end
  return M.get_todo_index(store)[todo_id]
end

function M.build_todo_fields(todo, parent_title)
  local fields = {
    item = todo.title,
    status = todo.status,
    priority = todo.priority,
    created = todo.created,
    completed = todo.completed,
    id = todo.id,
    parent = todo.parent_id,
    parent_title = parent_title,
    labels = table.concat(todo.labels or {}, ', '),
  }
  for _, field in ipairs(todo.extra_fields or {}) do
    fields[field.name] = field.value
  end
  return fields
end

function M.generate_todo_id(store)
  if not random_seeded then
    local seed = os.time()
    if vim.uv and vim.uv.hrtime then
      seed = seed + (vim.uv.hrtime() % 1000000)
    end
    math.randomseed(seed)
    random_seeded = true
  end

  local seen = {}
  for _, todo in ipairs(store.todos or {}) do
    if todo.id then
      seen[todo.id] = true
    end
  end
  while true do
    local candidate = string.format('t_%s_%04x', os.date('!%Y%m%d_%H%M%S'), math.random(0, 0xffff))
    if not seen[candidate] then
      return candidate
    end
  end
end

function M.build_item_from_todo(todo)
  local file = todo.source and todo.source.file or utils.get_todo_store_path()
  local lnum = todo.source and todo.source.lnum or 1

  return {
    file = file,
    pos = { lnum, 1 },
    text = todo.title,
    todo_id = todo.id,
    todo_parent_id = todo.parent_id,
    todo_text = todo.title,
    todo_fields = M.build_todo_fields(todo),
    todo_extra_fields = todo.extra_fields or {},
    todo_labels = todo.labels or {},
    todo_description = todo.description or '',
    todo_log = todo.log or todo.details or {},
    todo_details = todo.log or todo.details or {},
    todo_reference = {
      file = todo.reference and todo.reference.file,
      lnum = todo.reference and todo.reference.lnum,
    },
    todo_source = {
      file = todo.source and todo.source.file,
      lnum = todo.source and todo.source.lnum,
      todo_id = todo.source and todo.source.todo_id,
    },
  }
end

function M.get_todo_item_by_id(todo_id)
  if not todo_id or todo_id == '' then
    return nil
  end

  local store = M.load_store()
  local bucket = M.find_todo_bucket(store, todo_id)
  if not bucket then
    return nil
  end

  return M.build_item_from_todo(bucket.todo)
end

function M.create_todo_record(store, spec)
  local todo = M.normalize_todo(vim.tbl_extend('force', {
    id = M.generate_todo_id(store),
    title = '',
    status = config.STATUS_TODO,
    priority = config.PRIORITY_LOW,
    created = utils.today(),
    completed = nil,
    parent_id = nil,
    description = '',
    log = {},
    labels = {},
    extra_fields = {},
    source = {},
    reference = {},
  }, spec or {}))

  if not todo.id then
    todo.id = M.generate_todo_id(store)
  end

  M.ensure_todo_source(todo)

  store.todos[#store.todos + 1] = todo
  return todo
end

function M.update_todo_by_id(todo_id, mutator)
  local result = M.with_todo_store(function(store, index)
    local idx = index[todo_id]
    if not idx then
      return false
    end

    local before = vim.deepcopy(idx.todo)
    local mutated = mutator(vim.deepcopy(idx.todo))
    if type(mutated) ~= 'table' then
      return false
    end

    local after = M.normalize_todo(mutated)
    if not after.id then
      after.id = before.id
    end

    M.ensure_todo_source(after)

    store.todos[idx.idx] = after
    if before.title ~= after.title then
      local markdown = require('todo-picker.markdown')
      markdown.update_reference_line_for_todo(after, store)
    end

    return {
      changed = not vim.deep_equal(before, after),
      item = M.build_item_from_todo(after),
    }
  end)

  if not result then
    return false, nil
  end

  return result.changed == true, result.item
end

function M.relationship_would_create_cycle(index, child_id, new_parent_id)
  if not child_id or not new_parent_id then
    return false
  end
  if child_id == new_parent_id then
    return true
  end

  local seen = {}
  local current_id = new_parent_id
  while current_id and current_id ~= '' do
    if current_id == child_id then
      return true
    end
    if seen[current_id] then
      return true
    end
    seen[current_id] = true

    local bucket = index[current_id]
    if not bucket or not bucket.todo then
      break
    end
    current_id = bucket.todo.parent_id
  end

  return false
end

function M.set_todo_parent_relationship(child_id, parent_id)
  if not child_id or child_id == '' then
    return false, 'Source todo not found'
  end

  local store = M.load_store()
  local index = M.get_todo_index(store)
  local child_bucket = index[child_id]
  if not child_bucket then
    return false, 'Source todo not found'
  end

  local normalized_parent_id = (parent_id and parent_id ~= '') and parent_id or nil
  if normalized_parent_id then
    if not index[normalized_parent_id] then
      return false, 'Selected related todo was not found'
    end
    if M.relationship_would_create_cycle(index, child_id, normalized_parent_id) then
      return false, 'Relationship blocked: this would create a parent/child cycle'
    end
  end

  local child_todo = child_bucket.todo
  if child_todo.parent_id == normalized_parent_id then
    return true, nil
  end

  child_todo.parent_id = normalized_parent_id
  if not M.write_store(store) then
    return false, 'Could not save relationship update'
  end

  return true, nil
end

function M.unlink_relationship_between(first_id, second_id)
  if not first_id or first_id == '' or not second_id or second_id == '' then
    return false, 'Could not resolve relationship pair', nil
  end

  local store = M.load_store()
  local index = M.get_todo_index(store)
  local first_bucket = index[first_id]
  local second_bucket = index[second_id]
  if not first_bucket or not second_bucket then
    return false, 'Selected related todo was not found', nil
  end

  local changed_child_id
  if first_bucket.todo.parent_id == second_id then
    first_bucket.todo.parent_id = nil
    changed_child_id = first_id
  elseif second_bucket.todo.parent_id == first_id then
    second_bucket.todo.parent_id = nil
    changed_child_id = second_id
  else
    return false, 'No direct parent/child relationship exists between selected todos', nil
  end

  if not M.write_store(store) then
    return false, 'Could not save relationship update', nil
  end

  return true, nil, changed_child_id
end

function M.delete_todo_by_id(todo_id)
  local store = M.load_store()
  local bucket = M.find_todo_bucket(store, todo_id)
  if not bucket then
    return false
  end

  local todo = bucket.todo
  local markdown = require('todo-picker.markdown')
  local ref_file, ref_lnum = markdown.resolve_reference(todo, store)

  if ref_file and ref_lnum then
    local bufnr = utils.get_loaded_bufnr(ref_file)
    if bufnr then
      local line = vim.api.nvim_buf_get_lines(bufnr, ref_lnum - 1, ref_lnum, false)[1] or ''
      local parsed = markdown.parse_reference_line(line)
      if parsed and parsed.todo_id == todo_id then
        vim.api.nvim_buf_set_lines(bufnr, ref_lnum - 1, ref_lnum, false, {})
        utils.maybe_write_buffer(bufnr)
      end
    end

    markdown.adjust_reference_lines_after_insert(store, ref_file, (ref_lnum or 0) + 1, -1, todo_id)
  end

  table.remove(store.todos, bucket.idx)
  return M.write_store(store)
end

return M
