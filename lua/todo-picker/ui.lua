local M = {}

local config = require("todo-picker.config")
local utils = require("todo-picker.utils")
local store = require("todo-picker.store")
local markdown = require("todo-picker.markdown")

local detail_panel_stack = {}

local function collect_direct_subtasks(store_obj, parent_id)
	local subtasks = {}
	if not parent_id or parent_id == "" then
		return subtasks
	end
	for _, todo in ipairs(store_obj.todos or {}) do
		if todo.parent_id == parent_id then
			subtasks[#subtasks + 1] = todo
		end
	end
	table.sort(subtasks, function(a, b)
		local a_status = config.STATUS_SORT[a.status] or 9
		local b_status = config.STATUS_SORT[b.status] or 9
		if a_status ~= b_status then
			return a_status < b_status
		end

		local a_completed_sort = utils.parse_date_to_sortkey(a.completed)
		local b_completed_sort = utils.parse_date_to_sortkey(b.completed)
		local a_completed_rank = 99999999
		local b_completed_rank = 99999999
		if a_status == (config.STATUS_SORT[config.STATUS_DONE] or 2) and a_completed_sort >= 0 then
			a_completed_rank = 99999999 - a_completed_sort
		end
		if b_status == (config.STATUS_SORT[config.STATUS_DONE] or 2) and b_completed_sort >= 0 then
			b_completed_rank = 99999999 - b_completed_sort
		end
		if a_completed_rank ~= b_completed_rank then
			return a_completed_rank < b_completed_rank
		end

		local a_priority = config.PRIORITY_SORT[a.priority] or 9
		local b_priority = config.PRIORITY_SORT[b.priority] or 9
		if a_priority ~= b_priority then
			return a_priority < b_priority
		end

		local ar = utils.parse_date_to_sortkey(a.created)
		local br = utils.parse_date_to_sortkey(b.created)
		local a_created_rank = ar >= 0 and ar or 99999999
		local b_created_rank = br >= 0 and br or 99999999
		if a_created_rank ~= b_created_rank then
			return a_created_rank < b_created_rank
		end
		return (a.id or "") < (b.id or "")
	end)
	return subtasks
end

function M.confirm_delete_todos(items)
	if not items or #items == 0 then
		return false
	end

	local names = {}
	for _, item in ipairs(items) do
		names[#names + 1] = item.todo_text or item.todo_fields and item.todo_fields.item or item.text or "Untitled task"
	end

	local prompt
	if #names == 1 then
		prompt = "Delete this todo?\n\n" .. names[1]
	else
		prompt = string.format("Delete %d todos?", #names)
	end

	return vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1
end

function M.open_new_todo_draft(picker, picker_context, draft)
	M.open_todo_detail(picker, nil, {
		start_zone = "title",
		start_insert = true,
		create_mode = true,
		picker_context = picker_context,
		draft = draft,
	})
end

function M.open_todo_detail(picker, item, opts)
	opts = opts or {}
	local w = math.floor(vim.o.columns * 0.8)
	local editor_height = vim.o.lines - vim.o.cmdheight
	if vim.o.laststatus > 0 then
		editor_height = editor_height - 1
	end
	if vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1) then
		editor_height = editor_height - 1
	end
	local h = math.floor(editor_height * 0.80)
	local row = math.floor((vim.o.lines - h) / 2)
	local col = math.floor((vim.o.columns - w) / 2)

	local target_win = nil
	if picker then
		if picker.layout then
			local win_val = picker.layout.win
			if type(win_val) == "number" and vim.api.nvim_win_is_valid(win_val) then
				target_win = win_val
			elseif type(win_val) == "table" and type(win_val.win) == "number" and vim.api.nvim_win_is_valid(win_val.win) then
				target_win = win_val.win
			end
		end
		if not target_win and picker.list then
			local win_val = picker.list.win
			if type(win_val) == "number" and vim.api.nvim_win_is_valid(win_val) then
				target_win = win_val
			elseif type(win_val) == "table" and type(win_val.win) == "number" and vim.api.nvim_win_is_valid(win_val.win) then
				target_win = win_val.win
			end
		end
	end

	if target_win then
		local pos = vim.fn.win_screenpos(target_win)
		if pos and pos[1] > 0 and pos[2] > 0 then
			row = pos[1] - 2
			col = pos[2] - 2
			w = vim.api.nvim_win_get_width(target_win)
			h = vim.api.nvim_win_get_height(target_win)
		end
	end
	if item and item.todo_is_tag_header then
		require("todo-picker.picker").picker_toggle_subtasks(picker, item)
		return
	end
	if item and item.todo_is_empty_state then
		M.open_new_todo_draft(picker, require("todo-picker.picker").capture_picker_reopen_context(picker, item), {
			title = "",
			parent_id = nil,
			create_reference = false,
		})
		return
	end

	local draft = opts.draft
	local is_create_mode = opts.create_mode == true
	local is_draft = is_create_mode and type(draft) == "table"
	local store_obj = store.load_store()
	local todo
	local source_file
	local source_lnum
	local reference_file
	local reference_lnum

	if is_draft then
		todo = store.normalize_todo({
			title = draft.title or "",
			status = draft.status or config.STATUS_TODO,
			priority = draft.priority or config.PRIORITY_LOW,
			created = draft.created or utils.today(),
			completed = draft.completed,
			parent_id = draft.parent_id,
			description = draft.description or "",
			log = draft.log or draft.details or {},
			labels = draft.labels or {},
			extra_fields = draft.extra_fields or {},
			source = {
				file = draft.source and draft.source.file,
				lnum = draft.source and draft.source.lnum,
				todo_id = draft.source and draft.source.todo_id,
			},
			reference = {
				file = draft.reference and draft.reference.file,
				lnum = draft.reference and draft.reference.lnum,
			},
		})
		source_file = todo.source and todo.source.file
		source_lnum = todo.source and todo.source.lnum
		reference_file = todo.reference and todo.reference.file
		reference_lnum = todo.reference and todo.reference.lnum
	else
		if not item or not item.todo_id then
			return
		end

		local idx = store.find_todo_bucket(store_obj, item.todo_id)
		if not idx then
			utils.notify_todo("Todo not found in store", vim.log.levels.WARN)
			return
		end
		todo = idx.todo
		store.ensure_todo_source(todo)
		source_file = todo.source and todo.source.file or utils.get_todo_store_path()
		source_lnum = todo.source and todo.source.lnum
		reference_file, reference_lnum = markdown.resolve_reference(todo, store_obj)
	end

	local UI = config.options.ui
	local status = todo.status
	local priority = todo.priority
	local created_date = todo.created
	local completed_date = todo.completed or ""
	local msg = todo.title
	local description = todo.description or ""
	local log_entries = vim.deepcopy(todo.log or todo.details or {})
	local labels = vim.deepcopy(todo.labels or {})
	local extra_fields = vim.deepcopy(todo.extra_fields or {})
	local direct_subtasks = is_draft and {} or collect_direct_subtasks(store_obj, todo.id)
	local picker_context = opts.picker_context
		or require("todo-picker.picker").capture_picker_reopen_context(picker, item)


	local panel_context = {
		picker = picker,
		picker_context = picker_context,
		todo_id = todo.id,
	}

	local lines = {}
	local hls = {}
	local span_hls = {}
	local function push(text, hl)
		lines[#lines + 1] = text
		if hl then
			hls[#hls + 1] = { #lines - 1, hl }
		end
	end

	local function push_segments(parts)
		local text = ""
		local col = 0
		for _, part in ipairs(parts) do
			local segment = tostring(part[1] or "")
			local hl = part[2]
			text = text .. segment
			local next_col = col + #segment
			if hl and segment ~= "" then
				span_hls[#span_hls + 1] = { #lines, col, next_col, hl }
			end
			col = next_col
		end
		lines[#lines + 1] = text
	end

	local inner_width = w - 2 - #UI.panel.indent - 2
	local sep = UI.panel.indent .. string.rep(UI.panel.section_sep_char, inner_width)
	local reference_rel = vim.fn.fnamemodify(reference_file or "", ":~:.")
	local reference_value = ""
	if reference_rel ~= "" and reference_lnum then
		reference_value = reference_rel .. ":" .. tostring(reference_lnum)
	end
	local meta_label_width = UI.panel.meta_label_width
	local current_status = status
	local current_priority = priority
	local current_created_date = created_date
	local current_completed_date = completed_date

	local function status_value(s)
		return config.STATUS_LABEL[s] or s or ""
	end
	local function priority_value(p)
		return p or ""
	end
	local function meta_row(label, value)
		return string.format("%s%-" .. meta_label_width .. "s%s", UI.panel.indent, label .. ":", value)
	end
	local priority_badges = {
		[config.PRIORITY_HIGH] = "●",
		[config.PRIORITY_MEDIUM] = "●",
		[config.PRIORITY_LOW] = " ",
	}

	local status_icons = {
		[config.STATUS_TODO] = "",
		[config.STATUS_BLOCKED] = "",
		[config.STATUS_DOING] = "",
		[config.STATUS_PEER_REVIEW] = "",
		[config.STATUS_DONE] = "",
	}

	local status_color_hl = config.STATUS_COLOR[config.STATUS_SORT[status] or 0] or "Normal"
	local priority_hl = config.PRIORITY_HL[priority] or "NonText"

	local function section(icon, title)
		push_segments({
			{ UI.panel.indent },
			{ icon .. " ", "SnacksPickerKeymapLhs" },
			{ title, "SnacksPickerKeymapLhs" }
		})
		push(sep, "Comment")
	end

	-- Push Task Title as Header
	push_segments({
		{ UI.panel.indent },
		{ "󰓌 ", "SnacksPickerKeymapLhs" },
		{ msg, "SnacksPickerKeymapLhs" }
	})
	local title_line_num = #lines
	push(sep, "Comment")
	push("")

	section("", "Description")
	local description_first_line
	local description_last_line
	local description_input_line
	local has_description_content = vim.trim(description) ~= ""
	local description_lines = vim.split(description, "\n", { plain = true, trimempty = false })
	if #description_lines == 0 then
		description_lines = { "" }
	end
	for _, desc_line in ipairs(description_lines) do
		push(UI.panel.details_indent .. desc_line, "Normal")
		if not description_first_line then
			description_first_line = #lines
		end
		description_last_line = #lines
	end
	if not description_first_line then
		push(UI.panel.indent, "Normal")
		description_first_line = #lines
		description_last_line = #lines
	end
	if has_description_content then
		push(UI.panel.indent, "Normal")
		description_input_line = #lines
		description_last_line = #lines
	else
		description_input_line = description_last_line
	end

	push("")
	section("", "Log")
	local log_first_line
	local log_last_line
	local log_input_line
	if #log_entries > 0 then
		for _, entry in ipairs(log_entries) do
			push(UI.panel.details_indent .. "• " .. entry, "Normal")
			if not log_first_line then
				log_first_line = #lines
			end
			log_last_line = #lines
		end
		push(UI.panel.indent, "Normal")
		log_input_line = #lines
		log_last_line = #lines
	else
		push(UI.panel.indent, "Normal")
		log_first_line = #lines
		log_last_line = #lines
		log_input_line = #lines
	end

	push("")
	section("", "Tags")
	local tags_first_line
	local tags_last_line
	local tags_input_line
	for _, label in ipairs(labels) do
		push(UI.panel.indent .. "#" .. label, "Normal")
		if not tags_first_line then
			tags_first_line = #lines
		end
		tags_last_line = #lines
	end
	if #extra_fields > 0 then
		for _, field in ipairs(extra_fields) do
			push_segments({
				{ UI.panel.indent },
				{ string.format("%-" .. meta_label_width .. "s", field.name .. ":"), "Comment" },
				{ field.value or "", "Normal" }
			})
			if not tags_first_line then
				tags_first_line = #lines
			end
			tags_last_line = #lines
		end
		push(UI.panel.indent, "Normal")
		tags_input_line = #lines
		tags_last_line = #lines
	else
		push(UI.panel.indent, "Normal")
		tags_first_line = #lines
		tags_input_line = #lines
		tags_last_line = #lines
	end

	push("")
	section("⚙", "Meta")
	local parent_title = ""
	if todo.parent_id and todo.parent_id ~= "" then
		local parent_bucket = store.find_todo_bucket(store_obj, todo.parent_id)
		if parent_bucket and parent_bucket.todo then
			parent_title = parent_bucket.todo.title
		else
			parent_title = todo.parent_id
		end
	end

	-- Push Status field
	push_segments({
		{ UI.panel.indent },
		{ string.format("%-" .. meta_label_width .. "s", "Status:"), "Comment" },
		{ (status_icons[status] or "") .. " " .. status_value(status), status_color_hl }
	})
	local status_row_line = #lines

	-- Push Priority field
	push_segments({
		{ UI.panel.indent },
		{ string.format("%-" .. meta_label_width .. "s", "Priority:"), "Comment" },
		{ (priority_badges[priority] or " ") .. " " .. priority_value(priority), priority_hl }
	})
	local priority_row_line = #lines

	-- Push Created field
	push_segments({
		{ UI.panel.indent },
		{ string.format("%-" .. meta_label_width .. "s", "Created:"), "Comment" },
		{ created_date, "Normal" }
	})
	local created_row_line = #lines

	-- Push Completed field
	push_segments({
		{ UI.panel.indent },
		{ string.format("%-" .. meta_label_width .. "s", "Completed:"), "Comment" },
		{ completed_date ~= "" and completed_date or "—", completed_date ~= "" and "Comment" or "NonText" }
	})
	local completed_row_line = #lines

	if parent_title ~= "" then
		push_segments({
			{ UI.panel.indent },
			{ string.format("%-" .. meta_label_width .. "s", "Parent:"), "Comment" },
			{ parent_title, config.PARENT_HINT_HL }
		})
	end

	if #direct_subtasks > 0 then
		local child_titles = {}
		for _, subtask in ipairs(direct_subtasks) do
			table.insert(child_titles, subtask.title or "")
		end
		push_segments({
			{ UI.panel.indent },
			{ string.format("%-" .. meta_label_width .. "s", "Children:"), "Comment" },
			{ table.concat(child_titles, ", "), "Normal" }
		})
	end

	push_segments({
		{ UI.panel.indent },
		{ string.format("%-" .. meta_label_width .. "s", "Reference:"), "Comment" },
		{ reference_value ~= "" and reference_value or "—", reference_value ~= "" and "Underlined" or "NonText" }
	})
	local parent_row_line = #lines

	local help_line = #lines + 1

	local subtask_line_to_id = {}
	local subtasks_first_line
	local subtasks_last_line

	if #direct_subtasks > 0 then
		push("")
		section("󰔖", "Subtasks")
		for _, subtask in ipairs(direct_subtasks) do
			local sub_status = subtask.status or config.STATUS_TODO
			local sub_priority = subtask.priority or config.PRIORITY_LOW
			local status_hl = config.STATUS_COLOR[config.STATUS_SORT[sub_status] or -1] or "Normal"
			local title_hl = utils.title_highlight_for_status(sub_status, status_hl)
			if sub_status == config.STATUS_DONE then
				title_hl = "Comment" -- dimmed if done!
			end

			push_segments({
				{ UI.panel.indent .. "  ", "Comment" },
				{ (priority_badges[sub_priority] or " ") .. " ", config.PRIORITY_HL[sub_priority] or "NonText" },
				{ (status_icons[sub_status] or "") .. " ", status_hl },
				{ subtask.title or "", title_hl },
			})
			if not subtasks_first_line then
				subtasks_first_line = #lines
			end
			subtasks_last_line = #lines
			subtask_line_to_id[#lines] = subtask.id
		end
	end



	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = true
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.b[buf].completion = false
	vim.bo[buf].omnifunc = ""
	vim.bo[buf].completefunc = ""

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = w,
		height = h,
		row = row,
		col = col,
		style = "minimal",
		border = UI.panel.border,
		zindex = 200,
	})

	vim.wo[win].winhighlight = "Normal:Normal,FloatBorder:TodoTransparentBorder"

	if vim.fn.mode():sub(1, 1) == "i" then
		vim.cmd.stopinsert()
	end
	vim.wo[win].cursorline = false
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].virtualedit = "onemore"
	vim.wo[win].breakindent = true
	vim.wo[win].breakindentopt = UI.panel.breakindentopt
	local ns = vim.api.nvim_create_namespace("snacks_todo_detail")
	for _, hl in ipairs(hls) do
		vim.api.nvim_buf_add_highlight(buf, ns, hl[2], hl[1], 0, -1)
	end
	for _, span in ipairs(span_hls) do
		vim.api.nvim_buf_add_highlight(buf, ns, span[4], span[1], span[2], span[3])
	end

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = buf,
		callback = function()
			pcall(vim.api.nvim_buf_clear_namespace, buf, ns, title_line_num - 1, title_line_num)
			pcall(vim.api.nvim_buf_add_highlight, buf, ns, "SnacksPickerKeymapLhs", title_line_num - 1, 2, -1)
		end,
	})

	local help_win
	local function close_help()
		if help_win and vim.api.nvim_win_is_valid(help_win) then
			vim.api.nvim_win_close(help_win, true)
		end
		help_win = nil
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_set_current_win(win)
		end
	end

	local function toggle_help()
		if help_win and vim.api.nvim_win_is_valid(help_win) then
			close_help()
			return
		end

		local help_lines = {
			"  Detail Panel Keys",
			"",
			"  <CR>  Save and close",
			"  w     Save edits",
			"  q     Close panel",
			"  s     Cycle status",
			"  p     Cycle priority",
			"  D     Delete todo",
			"  r     Set relationship (choose direction + unlink)",
			"  P     Open parent details",
			"  c     Open selected child details",
			"  a     Add subtask",
			"  e     Open source (todo.json)",
			"  m     Open markdown reference",
			"  Tab   Next section",
			"  S-Tab Previous section",
			"  ?     Toggle this help",
		}

		local max_len = 0
		for _, line in ipairs(help_lines) do
			max_len = math.max(max_len, vim.fn.strdisplaywidth(line))
		end

		local hh = #help_lines
		local hw = math.max(40, math.min(max_len + 2, math.floor(vim.o.columns * 0.5)))

		local hbuf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(hbuf, 0, -1, false, help_lines)
		vim.bo[hbuf].modifiable = false
		vim.bo[hbuf].bufhidden = "wipe"
		vim.bo[hbuf].buftype = "nofile"

		help_win = vim.api.nvim_open_win(hbuf, true, {
			relative = "editor",
			width = hw,
			height = hh,
			row = math.floor((vim.o.lines - hh) / 2),
			col = math.floor((vim.o.columns - hw) / 2),
			style = "minimal",
			border = UI.panel.border,
			title = " Detail Help ",
			title_pos = "center",
			zindex = 210,
		})

		vim.wo[help_win].winhighlight = "Normal:Normal,FloatBorder:TodoTransparentBorder,FloatTitle:SnacksPickerKeymapLhs"

		vim.keymap.set("n", "q", close_help, { buffer = hbuf, nowait = true, silent = true })
		vim.keymap.set("n", "<Esc>", close_help, { buffer = hbuf, nowait = true, silent = true })
		vim.keymap.set("n", "?", close_help, { buffer = hbuf, nowait = true, silent = true })
	end

	local function parse_editor_block(editor_lines)
		local description_idx, log_idx, tags_idx, meta_idx
		for i, line in ipairs(editor_lines) do
			local t = vim.trim(line)
			if t:match("Description") then
				description_idx = i
			elseif t:match("Log") then
				log_idx = i
			elseif t:match("Tags") then
				tags_idx = i
			elseif t:match("Meta") then
				meta_idx = i
			end
		end

		if not description_idx or not log_idx or not tags_idx or not meta_idx then
			return nil, nil, nil, nil, nil
		end
		if not (description_idx < log_idx and log_idx < tags_idx and tags_idx < meta_idx) then
			return nil, nil, nil, nil, nil
		end

		local task_text = editor_lines[title_line_num] or ""
		task_text = task_text:gsub("^%s*󰓌%s*", ""):gsub("%s+$", "")

		local function is_separator_line(text)
			local compact = text:gsub("%s+", "")
			return compact ~= "" and compact:gsub("─", "") == ""
		end

		local description_lines_out = {}
		for i = description_idx + 1, log_idx - 1 do
			local raw = editor_lines[i] or ""
			if not is_separator_line(raw) then
				local value = raw:gsub("^%s+", "")
				description_lines_out[#description_lines_out + 1] = value
			end
		end
		while #description_lines_out > 0 and vim.trim(description_lines_out[1]) == "" do
			table.remove(description_lines_out, 1)
		end
		while #description_lines_out > 0 and vim.trim(description_lines_out[#description_lines_out]) == "" do
			table.remove(description_lines_out)
		end
		local description_text = table.concat(description_lines_out, "\n")

		local log_items = {}
		for i = log_idx + 1, tags_idx - 1 do
			local t = vim.trim(editor_lines[i] or "")
			if t ~= "" and not is_separator_line(t) then
				t = t:gsub("^•%s*", "")
				log_items[#log_items + 1] = t
			end
		end

		local tags = {}
		local labels_out = {}
		for i = tags_idx + 1, meta_idx - 1 do
			local t = vim.trim(editor_lines[i] or "")
			if t ~= "" and not is_separator_line(t) then
				local payload = vim.trim(t:match("^[-*+]%s*(.*)$") or t)
				payload = payload:gsub("^#%s*", "")
				local label = payload:match("^#(.+)$")
				if label and vim.trim(label) ~= "" then
					labels_out[#labels_out + 1] = vim.trim(label)
				else
					local name, value = payload:match("^([%w_]+)%s*[:=]%s*(.+)$")
					if name and value and value ~= "" and not store.CORE_FIELDS[name:lower()] then
						local normalized_value = vim.trim(value)
						if normalized_value ~= "value" then
							tags[#tags + 1] = { name = name:lower(), value = normalized_value }
						end
					else
						labels_out[#labels_out + 1] = payload
					end
				end
			end
		end

		return task_text, description_text, log_items, tags, labels_out
	end

	local function render_meta_rows()
		local status_hl_group = config.STATUS_COLOR[config.STATUS_SORT[current_status] or 0] or "Normal"
		local prio_hl_group = config.PRIORITY_HL[current_priority] or "NonText"

		local status_val_str = config.STATUS_LABEL[current_status] or current_status or ""
		local priority_val_str = current_priority or ""
		local created_val_str = current_created_date or ""
		local completed_val_str = current_completed_date ~= "" and current_completed_date or "—"

		local rows = {
			{ status_row_line, "Status:", status_hl_group, status_icons[current_status] or "", status_val_str },
			{ priority_row_line, "Priority:", prio_hl_group, priority_badges[current_priority] or " ", priority_val_str },
			{ created_row_line, "Created:", "Normal", nil, created_val_str },
			{ completed_row_line, "Completed:", current_completed_date ~= "" and "Comment" or "NonText", nil, completed_val_str },
		}

		for _, row in ipairs(rows) do
			local line_idx = row[1] - 1
			local label = row[2]
			local hl = row[3]
			local icon = row[4]
			local val = row[5]

			local icon_str = icon and (icon .. " ") or ""
			local text_val = icon_str .. val
			local text = string.format("%s%-" .. meta_label_width .. "s%s", UI.panel.indent, label, text_val)

			vim.bo[buf].modifiable = true
			vim.api.nvim_buf_set_lines(buf, line_idx, line_idx + 1, false, { text })
			vim.bo[buf].modifiable = false

			-- Clear namespace highlights on this specific line
			vim.api.nvim_buf_clear_namespace(buf, ns, line_idx, line_idx + 1)

			local indent_len = #UI.panel.indent
			-- Apply label highlight (dimmed Comment)
			vim.api.nvim_buf_add_highlight(buf, ns, "Comment", line_idx, indent_len, indent_len + meta_label_width)
			-- Apply value highlight
			vim.api.nvim_buf_add_highlight(buf, ns, hl, line_idx, indent_len + meta_label_width, -1)
		end
	end

	local function cycle_card_status()
		local today_date = utils.today()
		current_status = config.STATUS_NEXT[current_status] or config.STATUS_TODO
		if current_status == config.STATUS_DONE then
			current_completed_date = today_date
		elseif current_status == config.STATUS_TODO then
			current_created_date = today_date
			current_completed_date = ""
		else
			current_completed_date = ""
		end
		render_meta_rows()
	end

	local function cycle_card_priority()
		current_priority = config.PRIORITY_NEXT[current_priority] or config.PRIORITY_LOW
		render_meta_rows()
	end

	local save_edits
	local close_float

	local reopen_previous_detail_panel
	local transition_to_picker

	local function delete_from_detail()
		if is_draft or not todo.id then
			utils.notify_todo("This todo is not saved yet", vim.log.levels.WARN)
			return
		end

		if not M.confirm_delete_todos({ store.build_item_from_todo(todo) }) then
			return
		end

		if not store.delete_todo_by_id(todo.id) then
			utils.notify_todo("Could not delete todo", vim.log.levels.WARN)
			return
		end

		close_float()
		local kanban = require("todo-picker.kanban")
		if kanban.board_state.board_win and kanban.board_state.board_win:valid() then
			kanban.render_board()
		end
		require("todo-picker.picker").refresh_picker_items(picker, { focus_key = nil })
		if reopen_previous_detail_panel() then
			return
		end
		transition_to_picker()
	end

	save_edits = function()
		local editor_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local task_text, description_text, log_items, tags, labels_out = parse_editor_block(editor_lines)
		if task_text == nil then
			utils.notify_todo("Could not parse Description/Log/Tags sections", vim.log.levels.WARN)
			return false
		end

		local task = vim.trim(task_text)
		if task == "" then
			task = msg or ""
		end
		if task == "" then
			utils.notify_todo("Title cannot be empty", vim.log.levels.WARN)
			return false
		end

		local wrote
		local updated_item

		if is_draft then
			local create_store = store.load_store()
			local created_todo = store.create_todo_record(create_store, {
				title = task,
				status = current_status,
				priority = current_priority,
				created = current_created_date,
				completed = current_completed_date ~= "" and current_completed_date or nil,
				parent_id = draft.parent_id,
				description = description_text or "",
				log = utils.normalize_log_entries(log_items or {}, utils.today()),
				labels = store.normalize_labels(labels_out or {}),
				extra_fields = tags or {},
			})

			local should_create_reference = draft.create_reference == true
			if should_create_reference then
				local ref_file = draft.reference and draft.reference.file
				local ref_lnum = draft.reference and draft.reference.lnum
				local ref_insert_only = draft.reference and draft.reference.insert_only == true
				if not ref_file or not ref_lnum then
					utils.notify_todo("Missing markdown reference location for new todo", vim.log.levels.ERROR)
					return false
				end

				local ref_buf = utils.get_loaded_bufnr(ref_file)
				if not ref_buf then
					utils.notify_todo("Could not open markdown buffer for todo reference", vim.log.levels.ERROR)
					return false
				end

				local line_text = markdown.build_reference_line(task, created_todo.id)
				local inserted_lnum = markdown.create_reference_at_line(ref_buf, ref_lnum, line_text, ref_insert_only)
				created_todo.reference = {
					file = ref_file,
					lnum = inserted_lnum,
				}

				markdown.adjust_reference_lines_after_insert(
					create_store,
					ref_file,
					inserted_lnum + (ref_insert_only and 1 or 0),
					ref_insert_only and 1 or 0,
					created_todo.id
				)
				utils.maybe_write_buffer(ref_buf)
			end

			if not store.write_store(create_store) then
				return false
			end

			wrote = true
			updated_item = store.build_item_from_todo(created_todo)
		else
			wrote, updated_item = store.update_todo_by_id(todo.id, function(current)
				current.title = task
				current.status = current_status
				current.priority = current_priority
				current.created = current_created_date
				current.completed = current_completed_date ~= "" and current_completed_date or nil
				current.description = description_text or ""
				current.log = utils.normalize_log_entries(log_items or {}, utils.today())
				current.labels = store.normalize_labels(labels_out or {})
				current.extra_fields = tags or {}
				return current
			end)
		end

		if not wrote and not updated_item then
			return false
		end

		if updated_item and item then
			item.todo_text = updated_item.todo_text
			item.todo_fields = updated_item.todo_fields
			item.todo_extra_fields = updated_item.todo_extra_fields
			item.todo_labels = updated_item.todo_labels
			item.todo_description = updated_item.todo_description
			item.todo_log = updated_item.todo_log
			item.todo_details = updated_item.todo_details
			item.todo_reference = updated_item.todo_reference
			item.todo_source = updated_item.todo_source
		end

		require("todo-picker.picker").refresh_picker_items(
			picker,
			{ focus_key = require("todo-picker.picker").get_focus_key_for_item(updated_item or item) }
		)
		local kanban = require("todo-picker.kanban")
		if kanban.board_state.board_win and kanban.board_state.board_win:valid() then
			kanban.render_board()
		end
		return true
	end

	close_float = function()
		close_help()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	local function edit_relationship_from_detail(mode)
		if is_draft or not todo.id then
			utils.notify_todo("Save this task before setting relationships", vim.log.levels.WARN)
			return
		end

		if vim.fn.mode():sub(1, 1) == "i" then
			vim.cmd.stopinsert()
		end

		if not save_edits() then
			return
		end

		local source_item = store.get_todo_item_by_id(todo.id)
		if not source_item then
			utils.notify_todo("Todo not found in store", vim.log.levels.WARN)
			return
		end

		close_float()

		local picker_mod = require("todo-picker.picker")
		local relation_picker_opts = picker_mod.get_todo_picker_opts({
			title = string.format(
				"Relationship: %s -> pick second todo",
				source_item.todo_text or source_item.text or "todo"
			),
			apply_done_retention = false,
		})

		relation_picker_opts.win = relation_picker_opts.win or {}
		relation_picker_opts.win.input = relation_picker_opts.win.input or {}
		relation_picker_opts.win.input.keys = relation_picker_opts.win.input.keys or {}
		relation_picker_opts.win.list = relation_picker_opts.win.list or {}
		relation_picker_opts.win.list.keys = relation_picker_opts.win.list.keys or {}

		relation_picker_opts.win.input.keys["r"] = { "confirm", mode = { "n" }, desc = "select second todo" }
		relation_picker_opts.win.list.keys["r"] = { "confirm", mode = { "n" }, desc = "select second todo" }

		relation_picker_opts.confirm = function(rel_picker, candidate)
			local target = (rel_picker and rel_picker.current and rel_picker:current({ resolve = false })) or candidate
			if not target or not target.todo_id then
				return
			end

			if target.todo_id == source_item.todo_id then
				utils.notify_todo("Pick a different todo to define a relationship", vim.log.levels.WARN)
				return
			end

			if rel_picker and not rel_picker.closed and rel_picker.close then
				rel_picker:close()
			end

			local source_title = source_item.todo_text or source_item.text or "Untitled task"
			local target_title = target.todo_text or target.text or "Untitled task"
			local function finish_choice(choice)
				if choice then
					local ok, err
					if choice.kind == "unlink_pair" then
						ok, err = store.unlink_relationship_between(source_item.todo_id, target.todo_id)
					else
						ok, err = store.set_todo_parent_relationship(choice.child_id, choice.parent_id)
					end
					if not ok then
						utils.notify_todo(err or "Could not update relationship", vim.log.levels.WARN)
					else
						utils.notify_todo("Relationship updated")
					end
				end

				local refreshed_item = store.get_todo_item_by_id(todo.id)
				if refreshed_item then
					M.open_todo_detail(picker, refreshed_item, {
						start_zone = "log",
						start_insert = false,
						picker_context = panel_context.picker_context,
					})
				elseif reopen_previous_detail_panel() then
				-- previous panel reopened
				else
					transition_to_picker()
				end

				picker_mod.refresh_picker_items(picker, { focus_key = "id:" .. source_item.todo_id })
			end

			if mode == "source_child" then
				finish_choice({
					label = string.format('Make "%s" a child of "%s"', source_title, target_title),
					child_id = source_item.todo_id,
					parent_id = target.todo_id,
				})
				return
			end

			if mode == "source_parent" then
				finish_choice({
					label = string.format('Make "%s" a child of "%s"', target_title, source_title),
					child_id = target.todo_id,
					parent_id = source_item.todo_id,
				})
				return
			end

			local choices = {
				{
					label = string.format('Make "%s" a child of "%s"', source_title, target_title),
					child_id = source_item.todo_id,
					parent_id = target.todo_id,
				},
				{
					label = string.format('Make "%s" a child of "%s"', target_title, source_title),
					child_id = target.todo_id,
					parent_id = source_item.todo_id,
				},
				{
					label = string.format('Unlink relationship between "%s" and "%s"', source_title, target_title),
					kind = "unlink_pair",
				},
			}

			vim.ui.select(choices, {
				prompt = "Choose relationship direction:",
				format_item = function(choice)
					return choice.label
				end,
			}, finish_choice)
		end

		local relation_picker = Snacks.picker(relation_picker_opts)
		if relation_picker then
			vim.schedule(function()
				picker_mod.restore_picker_focus(relation_picker, "id:" .. source_item.todo_id)
			end)
		end
	end

	local function jump()
		close_float()
		if picker and picker.close then
			picker:close()
		end
		if is_draft then
			if draft.create_reference and draft.reference and draft.reference.file and draft.reference.lnum then
				utils.open_source_at(draft.reference.file, draft.reference.lnum)
			end
			return
		end

		local fresh_store = store.load_store()
		local fresh_idx = store.find_todo_bucket(fresh_store, todo.id)
		if not fresh_idx then
			return
		end
		store.ensure_todo_source(fresh_idx.todo)
		local target_file, target_lnum = markdown.resolve_source(fresh_idx.todo)
		if target_file then
			utils.open_source_at(target_file, target_lnum or 1)
		else
			utils.notify_todo("Source not found for this todo", vim.log.levels.WARN)
		end
	end

	local function jump_reference()
		close_float()
		if picker and picker.close then
			picker:close()
		end

		if is_draft then
			if draft.reference and draft.reference.file and draft.reference.lnum then
				utils.open_source_at(draft.reference.file, draft.reference.lnum)
			else
				utils.notify_todo("Reference not found for this todo", vim.log.levels.WARN)
			end
			return
		end

		local fresh_store = store.load_store()
		local fresh_idx = store.find_todo_bucket(fresh_store, todo.id)
		if not fresh_idx then
			return
		end

		local target_file, target_lnum = markdown.resolve_reference(fresh_idx.todo, fresh_store)
		if target_file and target_lnum then
			utils.open_source_at(target_file, target_lnum)
		else
			utils.notify_todo("Reference not found for this todo", vim.log.levels.WARN)
		end
	end

	local function add_subtask_from_detail()
		if not todo.id then
			utils.notify_todo("Save this task before adding subtasks", vim.log.levels.WARN)
			return
		end

		detail_panel_stack[#detail_panel_stack + 1] = {
			picker = picker,
			picker_context = panel_context.picker_context,
			todo_id = todo.id,
		}

		close_float()
		M.open_new_todo_draft(picker, panel_context.picker_context, {
			title = "",
			parent_id = todo.id,
			create_reference = false,
			labels = vim.deepcopy(todo.labels or {}),
			extra_fields = vim.deepcopy(todo.extra_fields or {}),
		})
	end

	local function open_parent_from_detail()
		local parent_id = todo.parent_id or (draft and draft.parent_id)
		if not parent_id or parent_id == "" then
			utils.notify_todo("This todo has no parent", vim.log.levels.WARN)
			return
		end

		local parent_item = store.get_todo_item_by_id(parent_id)
		if not parent_item then
			utils.notify_todo("Parent todo not found", vim.log.levels.WARN)
			return
		end

		detail_panel_stack[#detail_panel_stack + 1] = {
			picker = picker,
			picker_context = panel_context.picker_context,
			todo_id = todo.id,
		}

		close_float()
		M.open_todo_detail(picker, parent_item, {
			start_zone = "log",
			start_insert = false,
			picker_context = panel_context.picker_context,
		})
	end

	local function open_child_from_detail()
		if not subtasks_first_line then
			utils.notify_todo("This todo has no child tasks", vim.log.levels.WARN)
			return
		end

		local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
		local child_id = subtask_line_to_id[cursor_line]
		if not child_id then
			utils.notify_todo("Move cursor onto a subtask line first", vim.log.levels.WARN)
			return
		end

		local child_item = store.get_todo_item_by_id(child_id)
		if not child_item then
			utils.notify_todo("Child todo not found", vim.log.levels.WARN)
			return
		end

		detail_panel_stack[#detail_panel_stack + 1] = {
			picker = picker,
			picker_context = panel_context.picker_context,
			todo_id = todo.id,
		}

		close_float()
		M.open_todo_detail(picker, child_item, {
			start_zone = "log",
			start_insert = false,
			picker_context = panel_context.picker_context,
		})
	end

	reopen_previous_detail_panel = function()
		local previous = table.remove(detail_panel_stack)
		if not previous then
			return false
		end

		local store_now = store.load_store()
		local prev_idx = store.find_todo_bucket(store_now, previous.todo_id)
		if not prev_idx then
			require("todo-picker.picker").reopen_picker_from_context(previous.picker_context)
			return true
		end
		local prev_item = store.build_item_from_todo(prev_idx.todo)
		vim.schedule(function()
			M.open_todo_detail(previous.picker, prev_item, {
				start_zone = "log",
				start_insert = false,
				picker_context = previous.picker_context,
			})
		end)
		return true
	end

	transition_to_picker = function()
		if panel_context.picker_context then
			require("todo-picker.picker").reopen_picker_from_context(panel_context.picker_context)
		end
	end

	local function dismiss()
		if reopen_previous_detail_panel() then
			close_float()
			return
		end
		transition_to_picker()
		close_float()
		if vim.fn.mode():sub(1, 1) == "i" then
			vim.cmd.stopinsert()
		end
	end

	local function save_and_close()
		if vim.fn.mode():sub(1, 1) == "i" then
			vim.cmd.stopinsert()
		end
		if save_edits() then
			dismiss()
		end
	end

	local title_line = title_line_num or 1
	local title_col = 6
	local description_line = description_input_line or description_first_line or (title_line + 1)
	local description_col = 2
	local log_line = log_input_line or log_first_line or (description_line + 1)
	local log_col = 4
	local tags_line = tags_input_line or tags_first_line or (title_line + 1)
	local tags_col = 2
	local zones = {
		{ name = "title", line = title_line, col = title_col },
		{ name = "description", line = description_line, col = description_col },
		{ name = "log", line = log_line, col = log_col },
		{ name = "tags", line = tags_line, col = tags_col },
	}
	if subtasks_first_line then
		zones[#zones + 1] = { name = "subtasks", line = subtasks_first_line, col = 2 }
	end

	local function focus_zone(index, enter_insert)
		local zone = zones[index]
		if not zone then
			return
		end

		local target_line = zone.line
		local target_col = zone.col
		local line_text = vim.api.nvim_buf_get_lines(buf, target_line - 1, target_line, false)[1] or ""
		local end_col = vim.str_byteindex(line_text, vim.fn.strchars(line_text))

		if zone.name == "description" then
			target_col = math.max(description_col, end_col)
		elseif zone.name == "log" then
			target_col = math.max(log_col, end_col)
		elseif zone.name == "tags" then
			target_col = tags_col
		elseif zone.name == "title" then
			target_col = math.max(title_col, end_col + 1)
		end

		vim.api.nvim_win_set_cursor(win, { target_line, target_col })
		if enter_insert then
			vim.cmd("startinsert!")
		end
	end

	local function is_blank_editor_line(line_nr)
		local line_text = vim.api.nvim_buf_get_lines(buf, line_nr - 1, line_nr, false)[1] or ""
		return vim.trim(line_text) == ""
	end

	local function shift_subtask_lines(delta)
		if delta == 0 or not subtasks_first_line then
			return
		end

		subtasks_first_line = subtasks_first_line + delta
		subtasks_last_line = subtasks_last_line + delta

		local shifted = {}
		for line_nr, subtask_id in pairs(subtask_line_to_id) do
			shifted[line_nr + delta] = subtask_id
		end
		subtask_line_to_id = shifted
	end

	local function shift_meta_rows(delta)
		status_row_line = status_row_line + delta
		priority_row_line = priority_row_line + delta
		created_row_line = created_row_line + delta
		completed_row_line = completed_row_line + delta
		help_line = help_line + delta
		shift_subtask_lines(delta)
	end

	local function focus_description_input_row(create_if_needed)
		if not description_input_line then
			description_input_line = description_last_line or description_first_line or description_line
		end

		if create_if_needed and not is_blank_editor_line(description_input_line) then
			local insert_after = description_input_line
			vim.api.nvim_buf_set_lines(buf, insert_after, insert_after, false, { "  " })
			description_input_line = insert_after + 1
			description_last_line = description_last_line + 1
			log_first_line = log_first_line + 1
			log_last_line = log_last_line + 1
			log_input_line = log_input_line + 1
			tags_first_line = tags_first_line + 1
			tags_last_line = tags_last_line + 1
			tags_input_line = tags_input_line + 1
			zones[2].line = description_input_line
			zones[3].line = log_input_line
			zones[4].line = tags_input_line
			shift_meta_rows(1)
		end

		vim.api.nvim_win_set_cursor(win, { description_input_line, description_col })
		vim.cmd("startinsert!")
	end

	local function focus_log_input_row(create_if_needed)
		if not log_input_line then
			log_input_line = log_last_line or log_first_line or log_line
		end

		if create_if_needed and not is_blank_editor_line(log_input_line) then
			local insert_after = log_input_line
			vim.api.nvim_buf_set_lines(buf, insert_after, insert_after, false, { "  " })
			log_last_line = log_last_line + 1
			log_input_line = insert_after + 1
			tags_first_line = tags_first_line + 1
			tags_last_line = tags_last_line + 1
			tags_input_line = tags_input_line + 1
			zones[3].line = log_input_line
			zones[4].line = tags_input_line
			shift_meta_rows(1)
		end

		local line_text = vim.api.nvim_buf_get_lines(buf, log_input_line - 1, log_input_line, false)[1] or ""
		local end_col = vim.str_byteindex(line_text, vim.fn.strchars(line_text))
		vim.api.nvim_win_set_cursor(win, { log_input_line, math.max(log_col, end_col) })
		vim.cmd("startinsert!")
	end

	local function focus_tags_input_row(create_if_needed)
		if not tags_input_line then
			tags_input_line = tags_last_line or tags_first_line or tags_line
		end

		if create_if_needed and not is_blank_editor_line(tags_input_line) then
			local insert_after = tags_last_line or tags_input_line
			vim.api.nvim_buf_set_lines(buf, insert_after, insert_after, false, { "  " })
			tags_last_line = insert_after + 1
			tags_input_line = insert_after + 1
			zones[4].line = tags_input_line
			shift_meta_rows(1)
		end

		vim.api.nvim_win_set_cursor(win, { tags_input_line, tags_col })
		vim.cmd("startinsert!")
	end

	local function focus_subtask_line(use_last)
		if not subtasks_first_line then
			return
		end

		if vim.fn.mode():sub(1, 1) == "i" then
			vim.cmd.stopinsert()
		end

		local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
		local target = cursor_line
		if target < subtasks_first_line or target > subtasks_last_line then
			target = use_last and subtasks_last_line or subtasks_first_line
		end

		vim.api.nvim_win_set_cursor(win, { target, 2 })
	end

	local function step_subtask_line(forward)
		if not subtasks_first_line then
			return false
		end

		if vim.fn.mode():sub(1, 1) == "i" then
			vim.cmd.stopinsert()
		end

		local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
		if cursor_line < subtasks_first_line or cursor_line > subtasks_last_line then
			return false
		end

		if forward then
			if cursor_line < subtasks_last_line then
				vim.api.nvim_win_set_cursor(win, { cursor_line + 1, 2 })
				return true
			end
			return false
		end

		if cursor_line > subtasks_first_line then
			vim.api.nvim_win_set_cursor(win, { cursor_line - 1, 2 })
			return true
		end
		return false
	end

	local function is_in_tags_zone(line_nr)
		return line_nr >= (tags_first_line or 0) and line_nr <= (tags_last_line or -1)
	end

	local function is_in_log_zone(line_nr)
		return line_nr >= (log_first_line or 0) and line_nr <= (log_last_line or -1)
	end

	local function handle_tab(forward)
		local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
		local zone_name = zones[1].name
		for i, zone in ipairs(zones) do
			if cursor_line >= zone.line then
				zone_name = zone.name
			end
		end

		if forward then
			if zone_name == "title" then
				focus_description_input_row(true)
				return
			end
			if zone_name == "description" then
				focus_log_input_row(true)
				return
			end
			if zone_name == "log" then
				focus_tags_input_row(true)
				return
			end
			if zone_name == "tags" and subtasks_first_line then
				focus_subtask_line(false)
				return
			end
			if zone_name == "subtasks" then
				if step_subtask_line(true) then
					return
				end
				focus_zone(1, true)
				return
			end
			focus_zone(1, true)
			return
		end

		if zone_name == "subtasks" then
			if step_subtask_line(false) then
				return
			end
			focus_tags_input_row(false)
			return
		end
		if zone_name == "tags" then
			focus_log_input_row(false)
			return
		end
		if zone_name == "log" then
			focus_description_input_row(false)
			return
		end
		if zone_name == "description" then
			focus_zone(1, true)
			return
		end
		if zone_name == "title" then
			if subtasks_first_line then
				focus_subtask_line(true)
			else
				focus_tags_input_row(false)
			end
			return
		end
		focus_zone(1, true)
	end

	local function add_tag_row_below()
		local cursor = vim.api.nvim_win_get_cursor(win)
		local line_nr = cursor[1]
		if not is_in_tags_zone(line_nr) then
			return false
		end
		vim.api.nvim_buf_set_lines(buf, line_nr, line_nr, false, { "  " })
		tags_last_line = tags_last_line + 1
		tags_input_line = line_nr + 1
		zones[4].line = tags_input_line
		shift_meta_rows(1)
		vim.api.nvim_win_set_cursor(win, { line_nr + 1, tags_col })
		vim.cmd("startinsert")
		return true
	end

	local function add_log_row_below()
		local cursor = vim.api.nvim_win_get_cursor(win)
		local line_nr = cursor[1]
		if not is_in_log_zone(line_nr) then
			return false
		end
		vim.api.nvim_buf_set_lines(buf, line_nr, line_nr, false, { "  " })
		log_last_line = log_last_line + 1
		log_input_line = line_nr + 1
		tags_first_line = tags_first_line + 1
		tags_last_line = tags_last_line + 1
		tags_input_line = tags_input_line + 1
		zones[3].line = log_input_line
		zones[4].line = tags_input_line
		shift_meta_rows(1)
		vim.api.nvim_win_set_cursor(win, { line_nr + 1, log_col })
		vim.cmd("startinsert")
		return true
	end

	vim.keymap.set("n", "q", dismiss, { buffer = buf, nowait = true, silent = true })
	vim.keymap.set("n", "?", toggle_help, { buffer = buf, nowait = true, silent = true, desc = "show detail help" })
	vim.keymap.set("n", "<Esc>", dismiss, { buffer = buf, nowait = true, silent = true })
	vim.keymap.set("n", "<CR>", save_and_close, { buffer = buf, nowait = true, silent = true })
	vim.keymap.set("n", "e", jump, { buffer = buf, nowait = true, silent = true })
	vim.keymap.set("n", "m", jump_reference, { buffer = buf, nowait = true, silent = true })
	vim.keymap.set(
		"n",
		"a",
		add_subtask_from_detail,
		{ buffer = buf, nowait = true, silent = true, desc = "add subtask" }
	)
	vim.keymap.set(
		"n",
		"s",
		cycle_card_status,
		{ buffer = buf, nowait = true, silent = true, desc = "cycle todo status" }
	)
	vim.keymap.set("n", "D", delete_from_detail, { buffer = buf, nowait = true, silent = true, desc = "delete todo" })
	vim.keymap.set("n", "r", function()
		edit_relationship_from_detail(nil)
	end, { buffer = buf, nowait = true, silent = true, desc = "set parent/child relationship" })
	vim.keymap.set(
		"n",
		"P",
		open_parent_from_detail,
		{ buffer = buf, nowait = true, silent = true, desc = "open parent todo" }
	)
	vim.keymap.set(
		"n",
		"c",
		open_child_from_detail,
		{ buffer = buf, nowait = true, silent = true, desc = "open child todo under cursor" }
	)
	vim.keymap.set(
		"n",
		"p",
		cycle_card_priority,
		{ buffer = buf, nowait = true, silent = true, desc = "cycle todo priority" }
	)
	vim.keymap.set({ "n", "i" }, "<Tab>", function()
		handle_tab(true)
	end, { buffer = buf, nowait = true, silent = true, desc = "next todo card zone" })
	vim.keymap.set({ "n", "i" }, "<S-Tab>", function()
		handle_tab(false)
	end, { buffer = buf, nowait = true, silent = true, desc = "previous todo card zone" })
	vim.keymap.set("n", "w", save_edits, { buffer = buf, nowait = true, silent = true, desc = "save todo edits" })
	vim.keymap.set("i", "<CR>", function()
		if add_tag_row_below() then
			return
		end
		if add_log_row_below() then
			return
		end
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
	end, { buffer = buf, nowait = true, silent = true, desc = "new tag/log row or newline" })

	vim.schedule(function()
		if vim.api.nvim_win_is_valid(win) then
			local should_start_insert = opts.start_insert == true
			local zone = opts.start_zone
			if zone == "description" then
				focus_zone(2, should_start_insert)
			elseif zone == "log" or zone == "details" then
				focus_zone(3, should_start_insert)
			elseif zone == "tags" or zone == "newfield" then
				focus_zone(4, should_start_insert)
			elseif zone == "subtasks" and subtasks_first_line then
				focus_subtask_line(false)
			else
				focus_zone(1, should_start_insert)
			end
		end
	end)
end

return M
