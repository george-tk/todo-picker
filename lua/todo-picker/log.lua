local M = {}

local config = require("todo-picker.config")
local utils = require("todo-picker.utils")
local store = require("todo-picker.store")
local ui = require("todo-picker.ui")

local function parse_log_args(arg_str)
	arg_str = vim.trim(tostring(arg_str or ""))
	local tag_filter = nil

	local tag = arg_str:match("#([%w_%-]+)") or arg_str:match("tag:([%w_%-]+)")
	if tag then
		tag_filter = tag:lower()
		arg_str = arg_str:gsub("#[%w_%-]+", ""):gsub("tag:[%w_%-]+", "")
	end

	local range_type = vim.trim(arg_str)
	if range_type == "" then
		range_type = "week"
	end

	return range_type, tag_filter
end

local function parse_range_to_timestamps(range_arg)
	local now = os.time()
	local today_date_str = utils.today()
	local today_start = utils.parse_date_to_time(today_date_str) or now

	range_arg = tostring(range_arg or ""):lower():match("^%s*(.-)%s*$")

	if range_arg == "today" then
		return today_start, now, "Today (" .. today_date_str .. ")"
	elseif range_arg == "month" then
		local start_time = today_start - (30 * 86400)
		local start_date_str = os.date("%y/%m/%d", start_time)
		return start_time, now, "Past 30 Days (" .. start_date_str .. " - " .. today_date_str .. ")"
	else
		local days = tonumber(range_arg) or 7
		local start_time = today_start - ((days - 1) * 86400)
		local start_date_str = os.date("%y/%m/%d", start_time)
		local label = (days == 7) and ("Past 7 Days (" .. start_date_str .. " - " .. today_date_str .. ")")
			or ("Past " .. days .. " Days (" .. start_date_str .. " - " .. today_date_str .. ")")
		return start_time, now, label
	end
end

local function get_priority_icon(priority)
	priority = (priority or "LOW"):upper()
	if priority == config.PRIORITY_HIGH then
		return config.ICONS.priority.HIGH or "●", config.PRIORITY_HL[config.PRIORITY_HIGH] or "DiagnosticError"
	elseif priority == config.PRIORITY_MEDIUM then
		return config.ICONS.priority.MEDIUM or "●", config.PRIORITY_HL[config.PRIORITY_MEDIUM] or "DiagnosticWarn"
	else
		return nil, nil
	end
end

local function get_status_icon(status)
	if status == config.STATUS_DOING then
		return config.ICONS.status.DOING or "", config.STATUS_COLOR[2] or "DiagnosticWarn"
	elseif status == config.STATUS_BLOCKED then
		return config.ICONS.status.BLOCKED or "", config.STATUS_COLOR[1] or "DiagnosticError"
	elseif status == config.STATUS_PEER_REVIEW then
		return config.ICONS.status.PEER_REVIEW or "", config.STATUS_COLOR[3] or "Directory"
	elseif status == config.STATUS_DONE then
		return config.ICONS.status.DONE or "", config.STATUS_COLOR[4] or "Comment"
	else
		return config.ICONS.status.TODO or "", config.STATUS_COLOR[0] or "DiagnosticInfo"
	end
end

local function todo_has_tag(todo, target_tag)
	if not target_tag or target_tag == "" then
		return true
	end
	if not todo.labels then
		return false
	end
	for _, l in ipairs(todo.labels) do
		if tostring(l):lower() == target_tag then
			return true
		end
	end
	return false
end

function M.generate_log_panel(raw_arg_str, win_width)
	win_width = win_width or 68
	local sep_len = math.max(40, win_width - 4)

	local range_arg, tag_filter = parse_log_args(raw_arg_str)
	local start_time, end_time, range_label = parse_range_to_timestamps(range_arg)
	local store_obj = store.load_store()
	local todos = store_obj.todos or {}

	local title_by_id = {}
	for _, t in ipairs(todos) do
		title_by_id[t.id] = t.title
	end

	local completed_tasks = {}
	local activity_tasks = {}
	local focus_tasks = {}

	for _, t in ipairs(todos) do
		if todo_has_tag(t, tag_filter) then
			-- 1. Completed Tasks
			if t.status == config.STATUS_DONE and t.completed and t.completed ~= "" then
				local comp_time = utils.parse_date_to_time(t.completed)
				if comp_time and comp_time >= start_time and comp_time <= end_time then
					table.insert(completed_tasks, t)
				end
			end

			-- 2. Activity / Log Updates
			local logs = t.log or t.details or {}
			local matching_entries = {}
			for _, entry in ipairs(logs) do
				local date_str, msg = utils.parse_log_entry(tostring(entry or ""))
				if date_str then
					local log_time = utils.parse_date_to_time(date_str)
					if log_time and log_time >= start_time and log_time <= end_time then
						table.insert(matching_entries, { date = date_str, msg = msg })
					end
				end
			end
			if #matching_entries > 0 then
				table.insert(activity_tasks, { todo = t, entries = matching_entries })
			end

			-- 3. Active Focus Items
			if t.status == config.STATUS_DOING or t.status == config.STATUS_BLOCKED or t.status == config.STATUS_PEER_REVIEW then
				table.insert(focus_tasks, t)
			end
		end
	end

	local lines = {}
	local line_todo_map = {}
	local ticket_line_nums = {}
	local highlights = {}

	local function add_line(text)
		table.insert(lines, text)
		return #lines
	end

	-- Panel Title
	local filter_suffix = tag_filter and (" · #" .. tag_filter:upper()) or ""
	local title_text = " 📋 WORK LOG (" .. range_label:upper() .. ")" .. filter_suffix
	local title_lnum = add_line(title_text)
	table.insert(highlights, { line = title_lnum, s = 0, e = #title_text, hl = "Title" })

	local sep1 = " " .. string.rep("─", sep_len)
	local sep1_lnum = add_line(sep1)
	table.insert(highlights, { line = sep1_lnum, s = 0, e = #sep1, hl = "TodoTransparentBorder" })
	add_line("")

	-- Helper: Format Parent Title Hint
	local function get_parent_hint(t)
		if t.parent_id and t.parent_id ~= "" then
			local pname = title_by_id[t.parent_id] or t.parent_id
			return "  " .. config.ICONS.parent .. " " .. pname
		end
		return nil
	end

	-- Section 1: Completed Tasks
	local sec1_text = "  ✅ COMPLETED TASKS (" .. #completed_tasks .. ")"
	local sec1_lnum = add_line(sec1_text)
	table.insert(highlights, { line = sec1_lnum, s = 0, e = #sec1_text, hl = "SnacksPickerKeymapLhs" })

	if #completed_tasks == 0 then
		local empty_lnum = add_line("   No completed tasks recorded in this period.")
		table.insert(highlights, { line = empty_lnum, s = 0, e = #lines[empty_lnum], hl = "Comment" })
	else
		for _, t in ipairs(completed_tasks) do
			local prefix = "     "
			local line_text = prefix
			local s_title = #line_text
			line_text = line_text .. t.title
			local e_title = #line_text

			local parent_hint = get_parent_hint(t)
			local s_parent, e_parent
			if parent_hint then
				s_parent = #line_text
				line_text = line_text .. parent_hint
				e_parent = #line_text
			end

			local s_tags, e_tags
			if t.labels and #t.labels > 0 then
				local t_list = {}
				for _, l in ipairs(t.labels) do
					table.insert(t_list, config.ICONS.tag .. " " .. l)
				end
				local tags_str = "  " .. table.concat(t_list, " ")
				s_tags = #line_text
				line_text = line_text .. tags_str
				e_tags = #line_text
			end

			local lnum = add_line(line_text)
			line_todo_map[lnum] = store.build_item_from_todo(t)
			table.insert(ticket_line_nums, lnum)

			-- Title highlight (White font)
			table.insert(highlights, { line = lnum, s = s_title, e = e_title, hl = "Normal" })

			if s_parent then
				table.insert(highlights, { line = lnum, s = s_parent, e = e_parent, hl = config.PARENT_HINT_HL or "NonText" })
			end
			if s_tags then
				table.insert(highlights, { line = lnum, s = s_tags, e = e_tags, hl = config.PARENT_HINT_HL or "Comment" })
			end
		end
	end
	add_line("")

	-- Section 2: Progress & Activity Logs
	local sec2_text = "  📝 PROGRESS & ACTIVITY LOGS (" .. #activity_tasks .. ")"
	local sec2_lnum = add_line(sec2_text)
	table.insert(highlights, { line = sec2_lnum, s = 0, e = #sec2_text, hl = "SnacksPickerKeymapLhs" })

	if #activity_tasks == 0 then
		local empty_lnum = add_line("   No log updates recorded in this period.")
		table.insert(highlights, { line = empty_lnum, s = 0, e = #lines[empty_lnum], hl = "Comment" })
	else
		for _, item in ipairs(activity_tasks) do
			local t = item.todo
			local item_obj = store.build_item_from_todo(t)

			local prefix = "     "
			local line_text = prefix
			local s_icon, e_icon, s_hl, p_icon, p_hl

			if t.status ~= config.STATUS_DONE then
				s_icon, s_hl = get_status_icon(t.status)
				p_icon, p_hl = get_priority_icon(t.priority)

				local s_s = #line_text
				line_text = line_text .. s_icon
				local e_s = #line_text
				s_icon = { s = s_s, e = e_s, hl = s_hl }

				line_text = line_text .. " "
			end

			local s_title = #line_text
			line_text = line_text .. t.title
			local e_title = #line_text

			local s_p, e_p
			if t.status ~= config.STATUS_DONE and p_icon then
				line_text = line_text .. "  "
				s_p = #line_text
				line_text = line_text .. p_icon
				e_p = #line_text
			end

			local parent_hint = get_parent_hint(t)
			local s_parent, e_parent
			if parent_hint then
				s_parent = #line_text
				line_text = line_text .. parent_hint
				e_parent = #line_text
			end

			local s_tags, e_tags
			if t.labels and #t.labels > 0 then
				local t_list = {}
				for _, l in ipairs(t.labels) do
					table.insert(t_list, config.ICONS.tag .. " " .. l)
				end
				local tags_str = "  " .. table.concat(t_list, " ")
				s_tags = #line_text
				line_text = line_text .. tags_str
				e_tags = #line_text
			end


			local lnum = add_line(line_text)
			line_todo_map[lnum] = item_obj
			table.insert(ticket_line_nums, lnum)

			if s_icon then
				table.insert(highlights, { line = lnum, s = s_icon.s, e = s_icon.e, hl = s_icon.hl })
			end
			table.insert(highlights, { line = lnum, s = s_title, e = e_title, hl = "Normal" }) -- White title
			if s_p then
				table.insert(highlights, { line = lnum, s = s_p, e = e_p, hl = p_hl })
			end
			if s_parent then
				table.insert(highlights, { line = lnum, s = s_parent, e = e_parent, hl = config.PARENT_HINT_HL or "NonText" })
			end
			if s_tags then
				table.insert(highlights, { line = lnum, s = s_tags, e = e_tags, hl = config.PARENT_HINT_HL or "Comment" })
			end

			for _, entry in ipairs(item.entries) do
				local entry_prefix = "         "
				local date_part = entry.date
				local sep_part = " - "
				local msg_part = entry.msg

				local entry_line = entry_prefix .. date_part .. sep_part .. msg_part
				local elnum = add_line(entry_line)
				line_todo_map[elnum] = item_obj

				-- Highlight date in white (Normal)
				local ds = #entry_prefix
				local de = ds + #date_part
				table.insert(highlights, { line = elnum, s = ds, e = de, hl = "Normal" })

				-- Highlight message in Normal text
				local ms = de + #sep_part
				local me = ms + #msg_part
				table.insert(highlights, { line = elnum, s = ms, e = me, hl = "Normal" })
			end
		end
	end
	add_line("")

	-- Section 3: Active Focus (DOING, BLOCKED & PEER REVIEW)
	local sec3_text = "   ACTIVE FOCUS (" .. #focus_tasks .. ")"
	local sec3_lnum = add_line(sec3_text)
	table.insert(highlights, { line = sec3_lnum, s = 0, e = #sec3_text, hl = "SnacksPickerKeymapLhs" })

	if #focus_tasks == 0 then
		local empty_lnum = add_line("   No active DOING, BLOCKED, or REVIEW tasks.")
		table.insert(highlights, { line = empty_lnum, s = 0, e = #lines[empty_lnum], hl = "Comment" })
	else
		for _, t in ipairs(focus_tasks) do
			local s_icon, s_hl = get_status_icon(t.status)
			local p_icon, p_hl = get_priority_icon(t.priority)

			local prefix = "     "
			local line_text = prefix
			local s_s = #line_text
			line_text = line_text .. s_icon
			local e_s = #line_text

			line_text = line_text .. " "
			local s_title = #line_text
			line_text = line_text .. t.title
			local e_title = #line_text

			local s_p, e_p
			if p_icon then
				line_text = line_text .. "  "
				s_p = #line_text
				line_text = line_text .. p_icon
				e_p = #line_text
			end

			local parent_hint = get_parent_hint(t)
			local s_parent, e_parent
			if parent_hint then
				s_parent = #line_text
				line_text = line_text .. parent_hint
				e_parent = #line_text
			end

			local s_tags, e_tags
			if t.labels and #t.labels > 0 then
				local t_list = {}
				for _, l in ipairs(t.labels) do
					table.insert(t_list, config.ICONS.tag .. " " .. l)
				end
				local tags_str = "  " .. table.concat(t_list, " ")
				s_tags = #line_text
				line_text = line_text .. tags_str
				e_tags = #line_text
			end

			local lnum = add_line(line_text)
			local item_obj = store.build_item_from_todo(t)
			line_todo_map[lnum] = item_obj
			table.insert(ticket_line_nums, lnum)

			-- Status icon highlight
			table.insert(highlights, { line = lnum, s = s_s, e = e_s, hl = s_hl })
			-- Title highlight (White)
			table.insert(highlights, { line = lnum, s = s_title, e = e_title, hl = "Normal" })
			-- Priority dot highlight
			if s_p then
				table.insert(highlights, { line = lnum, s = s_p, e = e_p, hl = p_hl })
			end
			-- Parent hint highlight
			if s_parent then
				table.insert(highlights, { line = lnum, s = s_parent, e = e_parent, hl = config.PARENT_HINT_HL or "NonText" })
			end
			if s_tags then
				table.insert(highlights, { line = lnum, s = s_tags, e = e_tags, hl = config.PARENT_HINT_HL or "Comment" })
			end

			if t.status == config.STATUS_BLOCKED then
				local logs = t.log or t.details or {}
				if #logs > 0 then
					local last = logs[#logs]
					local date_str, msg = utils.parse_log_entry(tostring(last or ""))
					if date_str and msg then
						local entry_prefix = "         "
						local sep_part = " - "
						local note_line = entry_prefix .. date_str .. sep_part .. msg
						local nlnum = add_line(note_line)
						line_todo_map[nlnum] = item_obj

						-- Highlight date in white (Normal)
						local ds = #entry_prefix
						local de = ds + #date_str
						table.insert(highlights, { line = nlnum, s = ds, e = de, hl = "Normal" })

						-- Highlight message in Normal text
						local ms = de + #sep_part
						local me = ms + #msg
						table.insert(highlights, { line = nlnum, s = ms, e = me, hl = "Normal" })
					else
						local note_line = "         " .. tostring(last)
						local nlnum = add_line(note_line)
						line_todo_map[nlnum] = item_obj
						table.insert(highlights, { line = nlnum, s = 9, e = #note_line, hl = "Comment" })
					end
				end
			end
		end
	end
	add_line("")

	local sep2 = " " .. string.rep("─", sep_len)
	local sep2_lnum = add_line(sep2)
	table.insert(highlights, { line = sep2_lnum, s = 0, e = #sep2, hl = "TodoTransparentBorder" })

	local footer_text = "  Tab/S-Tab: navigate  Enter: open ticket  r: cycle range  y: copy  q: close"
	local footer_lnum = add_line(footer_text)
	table.insert(highlights, { line = footer_lnum, s = 0, e = #footer_text, hl = "Comment" })

	return lines, line_todo_map, ticket_line_nums, highlights
end

function M.open_work_log(raw_arg_str)
	local current_args = raw_arg_str or "week"
	local total_w = vim.o.columns
	local total_h = vim.o.lines
	local win_w = math.max(60, math.min(total_w - 6, math.floor(total_w * 0.8)))
	local win_h = math.max(15, math.min(total_h - 4, math.floor(total_h * 0.85)))
	local row = math.floor((total_h - win_h) / 2)
	local col = math.floor((total_w - win_w) / 2)

	local lines, line_todo_map, ticket_line_nums, highlights = M.generate_log_panel(current_args, win_w)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "todo_log"

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false

	-- Apply Highlights
	local ns = vim.api.nvim_create_namespace("todo_work_log_hl")
	pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
	for _, h in ipairs(highlights) do
		pcall(vim.api.nvim_buf_add_highlight, buf, ns, h.hl, h.line - 1, h.s, h.e)
	end

	local snacks = pcall(require, "snacks")
	local win_id = nil

	if snacks and Snacks.win then
		local win = Snacks.win({
			relative = "editor",
			width = win_w,
			height = win_h,
			row = row,
			col = col,
			border = "rounded",
			backdrop = 60,
			enter = true,
			focusable = true,
			buf = buf,
			wo = {
				winhighlight = "Normal:Normal,FloatBorder:TodoTransparentBorder",
				number = false,
				relativenumber = false,
				signcolumn = "no",
			},
		})
		win_id = win.win
	else
		win_id = vim.api.nvim_open_win(buf, true, {
			relative = "editor",
			width = win_w,
			height = win_h,
			row = row,
			col = col,
			style = "minimal",
			border = "rounded",
		})
		vim.wo[win_id].winhighlight = "Normal:Normal,FloatBorder:TodoTransparentBorder"
	end

	-- Move cursor to the first openable ticket if available
	if #ticket_line_nums > 0 then
		pcall(vim.api.nvim_win_set_cursor, win_id, { ticket_line_nums[1], 0 })
	end

	local function refresh_log()
		local new_lines, new_map, new_tickets, new_hls = M.generate_log_panel(current_args, win_w)
		line_todo_map = new_map
		ticket_line_nums = new_tickets
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
		vim.bo[buf].modifiable = false

		pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
		for _, h in ipairs(new_hls) do
			pcall(vim.api.nvim_buf_add_highlight, buf, ns, h.hl, h.line - 1, h.s, h.e)
		end
	end

	-- Keybindings helper
	local function map(keys, fn, desc)
		for _, k in ipairs(keys) do
			vim.keymap.set("n", k, fn, { buffer = buf, silent = true, desc = desc })
		end
	end

	map({ "q", "<Esc>" }, function()
		if win_id and vim.api.nvim_win_is_valid(win_id) then
			pcall(vim.api.nvim_win_close, win_id, true)
		end
	end, "Close Work Log")

	map({ "y" }, function()
		local text = table.concat(lines, "\n")
		vim.fn.setreg("+", text)
		vim.fn.setreg("*", text)
		vim.fn.setreg('"', text)
		utils.notify_todo("Copied Work Log report to clipboard!", vim.log.levels.INFO)
	end, "Yank Work Log Markdown")

	-- Range cycler keymap: r / t cycles today -> week -> month -> today
	map({ "r", "t" }, function()
		local range_type, tag_filter = parse_log_args(current_args)
		local next_range_map = {
			today = "week",
			week = "month",
			month = "today",
		}
		local next_range = next_range_map[range_type] or "week"
		if tag_filter then
			current_args = next_range .. " #" .. tag_filter
		else
			current_args = next_range
		end
		refresh_log()
	end, "Cycle Time Range (Today -> Week -> Month)")

	-- Navigation: Tab moves to next ticket line
	map({ "<Tab>" }, function()
		if #ticket_line_nums == 0 then
			return
		end
		local curr_lnum = vim.api.nvim_win_get_cursor(0)[1]
		local target_lnum = nil

		for _, lnum in ipairs(ticket_line_nums) do
			if lnum > curr_lnum then
				target_lnum = lnum
				break
			end
		end

		if not target_lnum then
			target_lnum = ticket_line_nums[1]
		end

		vim.api.nvim_win_set_cursor(0, { target_lnum, 0 })
	end, "Next Ticket Line")

	-- Navigation: S-Tab moves to previous ticket line
	map({ "<S-Tab>" }, function()
		if #ticket_line_nums == 0 then
			return
		end
		local curr_lnum = vim.api.nvim_win_get_cursor(0)[1]
		local target_lnum = nil

		for i = #ticket_line_nums, 1, -1 do
			local lnum = ticket_line_nums[i]
			if lnum < curr_lnum then
				target_lnum = lnum
				break
			end
		end

		if not target_lnum then
			target_lnum = ticket_line_nums[#ticket_line_nums]
		end

		vim.api.nvim_win_set_cursor(0, { target_lnum, 0 })
	end, "Previous Ticket Line")

	-- Open ticket without closing the log window
	map({ "<CR>", "gd" }, function()
		local lnum = vim.api.nvim_win_get_cursor(0)[1]
		local item = line_todo_map[lnum]
		if not item then
			utils.notify_todo("Cursor is not on an openable ticket line", vim.log.levels.WARN)
			return
		end

		ui.open_todo_detail(nil, item, {
			start_zone = "log",
			start_insert = false,
			on_close = function()
				refresh_log()
				if win_id and vim.api.nvim_win_is_valid(win_id) then
					vim.api.nvim_set_current_win(win_id)
				end
			end,
		})
	end, "Open Ticket Details")
end

return M
