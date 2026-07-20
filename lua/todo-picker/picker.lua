local M = {}

local config = require("todo-picker.config")
local utils = require("todo-picker.utils")
local store = require("todo-picker.store")
local markdown = require("todo-picker.markdown")

local function is_selectable(item)
	if not item then return false end
	if item.todo_is_empty_state then return false end
	if item.todo_is_tag_header == true then return false end
	if item.todo_id == "independent" then return false end
	if item.todo_flat_order == false and item.todo_depth == 0 then
		return false
	end
	return true
end

M.picker_hierarchy_ui_state = {
	collapsed_by_id = {},
	collapse_all = false,
}

local picker_help_windows = setmetatable({}, { __mode = "k" })

function M.close_picker_help(picker)
	local help_win = picker_help_windows[picker]
	if help_win and vim.api.nvim_win_is_valid(help_win) then
		vim.api.nvim_win_close(help_win, true)
	end
	picker_help_windows[picker] = nil
end

function M.toggle_picker_help(picker)
	if not picker then
		return
	end

	local help_win = picker_help_windows[picker]
	if help_win and vim.api.nvim_win_is_valid(help_win) then
		M.close_picker_help(picker)
		return
	end

	local help_lines = {
		"  Todo Picker Keys",
		"  (Search: Use '#tag' for tags, '@parent' for parent subtasks)",
		"",
		"  Enter  Open details",
		"  /      Toggle list and search focus",
		"  i      Focus search input",
		"  s      Cycle status",
		"  x      Cycle done visibility (hide/recent/all)",
		"  p      Cycle priority",
		"  r      Set relationship (choose direction + unlink)",
		"  P      Open parent details",
		"  t      Create sibling task",
		"  a      Create subtask",
		"  g      Group/Ungroup subtasks",
		"  z      Toggle subtasks",
		"  Z      Toggle all subtasks",
		"  D      Delete todo",
		"  e      Open source (todo.json)",
		"  m      Open markdown reference",
		"  ?      Toggle this help",
		"  q      Close picker",
	}

	local max_len = 0
	for _, line in ipairs(help_lines) do
		max_len = math.max(max_len, vim.fn.strdisplaywidth(line))
	end

	local h = #help_lines
	local w = math.max(44, math.min(max_len + 2, math.floor(vim.o.columns * 0.55)))

	local hbuf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(hbuf, 0, -1, false, help_lines)
	vim.bo[hbuf].modifiable = false
	vim.bo[hbuf].bufhidden = "wipe"
	vim.bo[hbuf].buftype = "nofile"

	local UI = config.options.ui
	help_win = vim.api.nvim_open_win(hbuf, true, {
		relative = "editor",
		width = w,
		height = h,
		row = math.floor((vim.o.lines - h) / 2),
		col = math.floor((vim.o.columns - w) / 2),
		style = "minimal",
		border = UI.panel.border,
		zindex = 210,
	})

	vim.wo[help_win].winhighlight = "Normal:Normal,FloatBorder:TodoTransparentBorder,FloatTitle:TodoFloatTitle"

	picker_help_windows[picker] = help_win

	local function close_help_window()
		M.close_picker_help(picker)
		if picker and not picker.closed and picker.focus then
			picker:focus("list")
		end
	end

	vim.keymap.set("n", "q", close_help_window, { buffer = hbuf, nowait = true, silent = true })
	vim.keymap.set("n", "<Esc>", close_help_window, { buffer = hbuf, nowait = true, silent = true })
	vim.keymap.set("n", "?", close_help_window, { buffer = hbuf, nowait = true, silent = true })
end

function M.compare_todo_entries_for_group(a, b)
	if a.status_rank ~= b.status_rank then
		return a.status_rank < b.status_rank
	end
	if a.completed_rank ~= b.completed_rank then
		return a.completed_rank < b.completed_rank
	end
	if a.priority_rank ~= b.priority_rank then
		return a.priority_rank < b.priority_rank
	end
	if a.created_rank ~= b.created_rank then
		return a.created_rank < b.created_rank
	end
	return (a.id or "") < (b.id or "")
end

function M.get_todo_hierarchy_index(store_obj)
	local index = {
		parent_to_child_count = {},
		id_to_parent = {},
		depth_by_todo_id = {},
		order_by_key = {},
		direct_done_by_todo_id = {},
		direct_total_by_todo_id = {},
	}

	local entries = {}
	local entries_by_id = {}
	local children_by_parent = {}

	local has_independent_parent = false
	for _, todo in ipairs(store_obj.todos or {}) do
		if todo.id == "independent" then
			has_independent_parent = true
			break
		end
	end

	local child_counts = {}
	for _, todo in ipairs(store_obj.todos or {}) do
		if todo.parent_id and todo.parent_id ~= "" and todo.parent_id ~= "independent" then
			child_counts[todo.parent_id] = (child_counts[todo.parent_id] or 0) + 1
		end
	end

	for _, todo in ipairs(store_obj.todos or {}) do
		local status_rank = config.STATUS_SORT[todo.status] or 9
		local priority_rank = config.PRIORITY_SORT[todo.priority] or 9
		local created_sort = utils.parse_date_to_sortkey(todo.created)
		local created_rank = created_sort >= 0 and created_sort or 99999999
		local completed_sort = utils.parse_date_to_sortkey(todo.completed)
		local completed_rank = 99999999
		if status_rank == (config.STATUS_SORT[config.STATUS_DONE] or 2) and completed_sort >= 0 then
			completed_rank = 99999999 - completed_sort
		end

		if todo.id == "independent" then
			status_rank = -999
			completed_rank = -999
			priority_rank = -999
			created_rank = -999
		end

		local parent_id = todo.parent_id
		if has_independent_parent and todo.id ~= "independent" then
			if (not parent_id or parent_id == "") and (not child_counts[todo.id] or child_counts[todo.id] == 0) then
				parent_id = "independent"
			end
		end

		local entry = {
			id = todo.id,
			parent_id = parent_id,
			status = todo.status,
			status_rank = status_rank,
			priority_rank = priority_rank,
			created_rank = created_rank,
			completed_rank = completed_rank,
		}
		entries[#entries + 1] = entry
		entries_by_id[todo.id] = entry
		index.id_to_parent[todo.id] = parent_id

		if parent_id then
			children_by_parent[parent_id] = children_by_parent[parent_id] or {}
			children_by_parent[parent_id][#children_by_parent[parent_id] + 1] = entry
			index.parent_to_child_count[parent_id] = (index.parent_to_child_count[parent_id] or 0) + 1
		end
	end

	local roots = {}
	for _, entry in ipairs(entries) do
		if not entry.parent_id or not entries_by_id[entry.parent_id] then
			roots[#roots + 1] = entry
		end
	end
	table.sort(roots, M.compare_todo_entries_for_group)

	for _, siblings in pairs(children_by_parent) do
		table.sort(siblings, M.compare_todo_entries_for_group)
	end

	local assigned = {}
	local order_counter = 0

	local function assign_tree_order(entry, depth, visiting, root_status_rank)
		if not entry or not entry.id or assigned[entry.id] or visiting[entry.id] then
			return
		end
		if root_status_rank == nil then
			root_status_rank = entry.status_rank or 9
		end

		visiting[entry.id] = true
		assigned[entry.id] = true
		order_counter = order_counter + 1

		index.order_by_key[entry.id] = root_status_rank * 10000000000 + order_counter
		index.depth_by_todo_id[entry.id] = depth

		for _, child in ipairs(children_by_parent[entry.id] or {}) do
			assign_tree_order(child, depth + 1, visiting, root_status_rank)
		end

		visiting[entry.id] = nil
	end

	for _, entry in ipairs(roots) do
		assign_tree_order(entry, 0, {}, nil)
	end

	for _, entry in ipairs(entries) do
		if not assigned[entry.id] then
			assign_tree_order(entry, 0, {}, nil)
		end
	end

	for parent_id, children in pairs(children_by_parent) do
		local done_count = 0
		for _, child in ipairs(children) do
			if child.status == config.STATUS_DONE then
				done_count = done_count + 1
			end
		end
		index.direct_done_by_todo_id[parent_id] = done_count
		index.direct_total_by_todo_id[parent_id] = #children
	end

	return index
end

function M.is_hidden_by_collapse(parent_id, hierarchy_state, hierarchy_index)
	if not parent_id then
		return false
	end
	if hierarchy_state and hierarchy_state.collapse_all then
		return true
	end

	local collapsed_by_id = hierarchy_state and hierarchy_state.collapsed_by_id or {}
	local id_to_parent = hierarchy_index and hierarchy_index.id_to_parent or {}
	local visited = {}
	local current = parent_id

	while current and current ~= "" and not visited[current] do
		if collapsed_by_id[current] then
			return true
		end
		visited[current] = true
		current = id_to_parent[current]
	end

	return false
end

function M.should_keep_done_item(item, apply_done_retention)
	local completed_date = item.todo_completed_date
	if completed_date == "" then
		return false
	end

	local completed_time = utils.parse_date_to_time(completed_date)
	if not completed_time then
		return false
	end

	if not apply_done_retention then
		return true
	end

	local age_days = math.floor((os.time() - completed_time) / 86400)
	return age_days <= config.options.done_retention_days
end

function M.get_group_by_mode(opts)
	if not opts then
		return "tag"
	end
	if opts.group_by then
		return opts.group_by
	end
	if opts.flat_order == true then
		return "none"
	else
		return "tag"
	end
end

function M.is_flat_order_enabled(opts)
	return M.get_group_by_mode(opts) == "none"
end

function M.get_done_visibility_mode(opts)
	opts = opts or {}

	local mode = opts.done_visibility
	if mode == "hide" or mode == "recent" or mode == "all" then
		return mode
	end

	if opts.include_done == false then
		return "hide"
	end
	if opts.apply_done_retention == false then
		return "all"
	end
	return "recent"
end

function M.build_quick_create_picker_item()
	local message = "New TODO"
	return {
		file = utils.get_todo_store_path(),
		pos = { 1, 1 },
		text = message,
		todo_text = message,
		todo_is_empty_state = true,
		todo_grouped_order = -9999999999999,
		todo_status = -1,
		todo_completed_sort_effective = -1,
		todo_priority_sort_effective = -1,
		todo_created_sort = -1,
		score = 999999999999,
	}
end

function M.collect_picker_items(opts)
	opts = opts or {}
	local store_obj = store.load_store()
	local hierarchy_index = M.get_todo_hierarchy_index(store_obj)
	local hierarchy_state = M.picker_hierarchy_ui_state
	local group_by = M.get_group_by_mode(opts)
	local flat_order = (group_by == "none")
	local only_done = opts.only_done == true
	local done_visibility = M.get_done_visibility_mode(opts)
	if only_done then
		done_visibility = "all"
	end

	local raw_todos = store_obj.todos or {}
	local todos = {}
	for _, t in ipairs(raw_todos) do
		table.insert(todos, t)
	end

	local has_independent = false
	if group_by == "parent" then
		local by_id = {}
		local parent_has_children = {}
		for _, t in ipairs(todos) do
			by_id[t.id] = t
			if t.parent_id and t.parent_id ~= "" then
				parent_has_children[t.parent_id] = true
			end
		end
		for _, t in ipairs(todos) do
			if (not t.parent_id or t.parent_id == "" or not by_id[t.parent_id]) and not parent_has_children[t.id] then
				has_independent = true
				break
			end
		end
	end

	if has_independent then
		table.insert(todos, {
			id = "independent",
			title = "Independent Tasks",
			status = "TODO",
			created = "1970-01-01",
			is_virtual = true,
		})
	end

	local mock_store_obj = { todos = todos }
	local hierarchy_index = M.get_todo_hierarchy_index(mock_store_obj)
	local hierarchy_state = M.picker_hierarchy_ui_state

	local title_by_id = {}
	for _, todo in ipairs(todos) do
		if todo.id then
			title_by_id[todo.id] = todo.title
		end
	end

	if group_by == "tag" then
		-- Group matching items by tag
		local items_by_tag = {}
		local all_tags_set = {}

		for _, todo in ipairs(todos) do
			local item = store.build_item_from_todo(todo)

			local status = config.STATUS_SORT[todo.status] or -1
			item.todo_status = status
			item.todo_status_value = todo.status
			item.todo_priority = todo.priority
			item.todo_priority_sort = config.PRIORITY_SORT[todo.priority] or 9
			item.todo_created_date = todo.created or ""
			item.todo_completed_date = todo.completed or ""
			item.todo_created_sort = utils.parse_date_to_sortkey(todo.created)
			item.todo_completed_sort = utils.parse_date_to_sortkey(todo.completed)
			item.todo_display_date = item.todo_completed_date ~= "" and item.todo_completed_date
				or item.todo_created_date
			item.todo_text = todo.title
			item.todo_id = todo.id
			item.todo_parent_id = todo.parent_id
			item.todo_parent_title = todo.parent_id and title_by_id[todo.parent_id] or nil
			item.todo_flat_order = false
			item.todo_group_by = "tag"

			item.todo_fields = store.build_todo_fields(todo, item.todo_parent_title)
			item.todo_extra_fields = todo.extra_fields or {}
			item.todo_labels = todo.labels or {}
			item.todo_description = todo.description or ""
			item.todo_log = todo.log or todo.details or {}
			item.todo_details = item.todo_log
			item.text = todo.title
			local status_val = tostring(todo.status or ""):lower()
			if status_val ~= "" then
				item.text = item.text .. " status=" .. status_val
			end
			local priority_val = tostring(todo.priority or ""):lower()
			if priority_val ~= "" then
				item.text = item.text .. " priority=" .. priority_val
			end
			if #item.todo_labels > 0 then
				for _, label in ipairs(item.todo_labels) do
					local clean = tostring(label):lower()
					if clean ~= "" then
						item.text = item.text .. " #" .. clean
					end
				end
			end
			if item.todo_parent_title and item.todo_parent_title ~= "" then
				local parent_clean = string.lower(item.todo_parent_title):gsub("%s+", "")
				local parent_lower = string.lower(item.todo_parent_title)
				item.text = item.text .. " @" .. parent_clean .. " parent:" .. parent_clean .. " [" .. parent_lower .. "]"
			end


			-- Check if we should keep this todo
			local is_done = status == config.STATUS_SORT[config.STATUS_DONE]
			local keep = false
			if
				(done_visibility ~= "hide" or status ~= config.STATUS_SORT[config.STATUS_DONE])
				and (not only_done or status == config.STATUS_SORT[config.STATUS_DONE])
			then
				keep = true
				if is_done then
					if done_visibility == "recent" then
						keep = M.should_keep_done_item(item, true)
					elseif done_visibility == "all" then
						keep = true
					else
						keep = false
					end
				end
			end

			if keep then
				local is_done = status == config.STATUS_SORT[config.STATUS_DONE]
				item.todo_priority_sort_effective = item.todo_priority_sort
				if is_done and item.todo_completed_sort >= 0 then
					item.todo_completed_sort_effective = 99999999 - item.todo_completed_sort
				else
					item.todo_completed_sort_effective = 99999999
				end

				local created_rank = item.todo_created_sort >= 0 and item.todo_created_sort or 99999999
				local status_rank = status >= 0 and status or 9
				item.score = 999999999999
					- (status_rank * 10000000000 + item.todo_priority_sort_effective * 100000000 + created_rank)

				local labels = todo.labels or {}
				if #labels > 0 then
					for _, label in ipairs(labels) do
						local clean_label = tostring(label)
						if clean_label ~= "" then
							items_by_tag[clean_label] = items_by_tag[clean_label] or {}
							table.insert(items_by_tag[clean_label], item)
							all_tags_set[clean_label] = true
						end
					end
				else
					local untagged_name = "Untagged"
					items_by_tag[untagged_name] = items_by_tag[untagged_name] or {}
					table.insert(items_by_tag[untagged_name], item)
					all_tags_set[untagged_name] = true
				end
			end
		end

		-- Collect and sort tag names
		local sorted_tags = {}
		for tag_name, _ in pairs(all_tags_set) do
			if tag_name ~= "Untagged" then
				table.insert(sorted_tags, tag_name)
			end
		end
		table.sort(sorted_tags, function(a, b)
			return string.lower(a) < string.lower(b)
		end)
		if all_tags_set["Untagged"] then
			table.insert(sorted_tags, 1, "Untagged")
		end

		local final_items = {}
		local order_counter = 0

		local function compare_items_by_rules(a, b)
			if a.todo_status ~= b.todo_status then
				return a.todo_status < b.todo_status
			end
			if a.todo_priority_sort ~= b.todo_priority_sort then
				return a.todo_priority_sort < b.todo_priority_sort
			end
			local rank_a = a.todo_created_sort >= 0 and a.todo_created_sort or 99999999
			local rank_b = b.todo_created_sort >= 0 and b.todo_created_sort or 99999999
			if rank_a ~= rank_b then
				return rank_a < rank_b
			end
			return (a.todo_id or "") < (b.todo_id or "")
		end

		for _, tag_name in ipairs(sorted_tags) do
			local tag_items = items_by_tag[tag_name] or {}
			table.sort(tag_items, compare_items_by_rules)

			local is_collapsed = hierarchy_state.collapsed_by_id["tag:" .. tag_name] == true
				or hierarchy_state.collapse_all == true

			order_counter = order_counter + 1
			local tag_header = {
				file = utils.get_todo_store_path(),
				pos = { 1, 1 },
				todo_id = "tag:" .. tag_name,
				todo_is_tag_header = true,
				todo_text = tag_name,
				text = tag_name,
				todo_status = -1,
				todo_status_value = "",
				todo_depth = 0,
				todo_has_children = true,
				todo_collapsed = is_collapsed,
				todo_flat_order = false,
				todo_group_by = "tag",
				todo_child_count = #tag_items,
				todo_grouped_order = order_counter,
				todo_status_effective = -1,
				todo_priority_sort_effective = -1,
				todo_created_sort = -1,
				score = 999999999999,
			}

			local done_count = 0
			for _, child_item in ipairs(tag_items) do
				if child_item.todo_status == config.STATUS_SORT[config.STATUS_DONE] then
					done_count = done_count + 1
				end
			end
			if done_count > 0 or #tag_items > 0 then
				tag_header.todo_progress_badge = string.format(" [%d/%d]", done_count, #tag_items)
			else
				tag_header.todo_progress_badge = ""
			end

			table.insert(final_items, tag_header)

			if not is_collapsed then
				for _, child_item in ipairs(tag_items) do
					local item_copy = vim.deepcopy(child_item)
					order_counter = order_counter + 1
					item_copy.todo_depth = 1
					item_copy.todo_parent_id = "tag:" .. tag_name
					item_copy.todo_has_children = false
					item_copy.todo_grouped_order = order_counter
					table.insert(final_items, item_copy)
				end
			end
		end

		table.insert(final_items, M.build_quick_create_picker_item())
		return final_items
	end

	local items = {}
	for _, todo in ipairs(todos) do
		local item = store.build_item_from_todo(todo)

		local status = config.STATUS_SORT[todo.status] or -1
		item.todo_status = status
		item.todo_status_value = todo.status
		item.todo_priority = todo.priority
		item.todo_priority_sort = config.PRIORITY_SORT[todo.priority] or 9
		item.todo_created_date = todo.created or ""
		item.todo_completed_date = todo.completed or ""
		item.todo_created_sort = utils.parse_date_to_sortkey(todo.created)
		item.todo_completed_sort = utils.parse_date_to_sortkey(todo.completed)
		item.todo_display_date = item.todo_completed_date ~= "" and item.todo_completed_date or item.todo_created_date
		item.todo_text = todo.title
		item.todo_id = todo.id
		item.todo_parent_id = todo.parent_id
		item.todo_parent_title = todo.parent_id and title_by_id[todo.parent_id] or nil
		item.todo_flat_order = flat_order
		item.todo_grouped_order = flat_order and 0 or (hierarchy_index.order_by_key[todo.id] or 900000000)
		item.todo_depth = flat_order and 0
			or (hierarchy_index.depth_by_todo_id[todo.id] or ((todo.parent_id and todo.parent_id ~= "") and 1 or 0))
		item.todo_child_count = hierarchy_index.parent_to_child_count[todo.id] or 0
		item.todo_has_children = not flat_order and item.todo_child_count > 0
		item.todo_collapsed = item.todo_has_children and hierarchy_state.collapsed_by_id[todo.id] == true or false
		item.todo_direct_done_count = hierarchy_index.direct_done_by_todo_id[todo.id] or 0
		item.todo_direct_total_count = hierarchy_index.direct_total_by_todo_id[todo.id] or 0
		if item.todo_has_children and item.todo_direct_total_count > 0 then
			item.todo_progress_badge =
				string.format(" [%d/%d]", item.todo_direct_done_count, item.todo_direct_total_count)
		else
			item.todo_progress_badge = ""
		end

		item.todo_fields = store.build_todo_fields(todo, item.todo_parent_title)
		item.todo_extra_fields = todo.extra_fields or {}
		item.todo_labels = todo.labels or {}
		item.todo_description = todo.description or ""
		item.todo_log = todo.log or todo.details or {}
		item.todo_details = item.todo_log
		item.text = todo.title
		local status_val = tostring(todo.status or ""):lower()
		if status_val ~= "" then
			item.text = item.text .. " status=" .. status_val
		end
		local priority_val = tostring(todo.priority or ""):lower()
		if priority_val ~= "" then
			item.text = item.text .. " priority=" .. priority_val
		end
		if #item.todo_labels > 0 then
			for _, label in ipairs(item.todo_labels) do
				local clean = tostring(label):lower()
				if clean ~= "" then
					item.text = item.text .. " #" .. clean
				end
			end
		end
		if item.todo_parent_title and item.todo_parent_title ~= "" then
			local parent_clean = string.lower(item.todo_parent_title):gsub("%s+", "")
			local parent_lower = string.lower(item.todo_parent_title)
			item.text = item.text .. " @" .. parent_clean .. " parent:" .. parent_clean .. " [" .. parent_lower .. "]"
		end

		local is_parent_with_children = flat_order and item.todo_child_count > 0
		if not is_parent_with_children then
			if
				(done_visibility ~= "hide" or status ~= config.STATUS_SORT[config.STATUS_DONE])
				and (not only_done or status == config.STATUS_SORT[config.STATUS_DONE])
				and (flat_order or not M.is_hidden_by_collapse(item.todo_parent_id, hierarchy_state, hierarchy_index))
			then
				local is_done = status == config.STATUS_SORT[config.STATUS_DONE]
				item.todo_priority_sort_effective = item.todo_priority_sort
				if is_done and item.todo_completed_sort >= 0 then
					item.todo_completed_sort_effective = 99999999 - item.todo_completed_sort
				else
					item.todo_completed_sort_effective = 99999999
				end

				local keep = true
				if status == config.STATUS_SORT[config.STATUS_DONE] then
					if done_visibility == "recent" then
						keep = M.should_keep_done_item(item, true)
					elseif done_visibility == "all" then
						keep = true
					else
						keep = false
					end
				end

				if keep then
					local created_rank = item.todo_created_sort >= 0 and item.todo_created_sort or 99999999
					local status_rank = status >= 0 and status or 9
					item.score = 999999999999
						- (status_rank * 10000000000 + item.todo_priority_sort_effective * 100000000 + created_rank)
					items[#items + 1] = item
				end
			end
		end
	end

	items[#items + 1] = M.build_quick_create_picker_item()

	return items
end

function M.get_focus_key_for_item(item)
	if not item then
		return nil
	end
	if item.todo_id and item.todo_id ~= "" then
		local key = "id:" .. item.todo_id
		if item.todo_parent_id and item.todo_parent_id ~= "" then
			key = key .. "@" .. item.todo_parent_id
		end
		return key
	end
	local file = item.file or ""
	local lnum = item.pos and item.pos[1]
	if file ~= "" and lnum then
		return "loc:" .. file .. ":" .. tostring(lnum)
	end
	return nil
end

function M.item_matches_focus_key(item, focus_key)
	if not item or not focus_key or focus_key == "" then
		return false
	end
	if focus_key:sub(1, 3) == "id:" then
		local key = "id:" .. (item.todo_id or "")
		if item.todo_parent_id and item.todo_parent_id ~= "" then
			key = key .. "@" .. item.todo_parent_id
		end
		return key == focus_key
	end
	if focus_key:sub(1, 4) == "loc:" then
		local file = item.file or ""
		local lnum = item.pos and item.pos[1]
		return ("loc:" .. file .. ":" .. tostring(lnum or "")) == focus_key
	end
	return false
end

function M.restore_picker_focus(picker, focus_key)
	if not picker or not focus_key or focus_key == "" or not picker.iter or not picker.list or not picker.list.view then
		return
	end
	for candidate, idx in picker:iter() do
		if M.item_matches_focus_key(candidate, focus_key) then
			picker.list:view(idx)
			return
		end
	end
end

function M.refresh_picker_items(picker, opts)
	if not picker then
		return
	end
	opts = opts or {}
	local focus_key = opts.focus_key

	if picker.finder then
		picker.finder.items = M.collect_picker_items((picker.opts and picker.opts._todo_format_opts) or {})
	end

	if picker.matcher and picker.matcher.run then
		picker.matcher:run(picker)
	end

	if picker.update then
		picker:update({ force = true })
	elseif picker.refresh then
		picker:refresh()
	end

	vim.schedule(function()
		M.restore_picker_focus(picker, focus_key)
	end)
end

function M.get_picker_hierarchy_state(picker)
	if picker and picker.opts then
		picker.opts._todo_hierarchy_state = M.picker_hierarchy_ui_state
		local format_opts = picker.opts._todo_format_opts
		if type(format_opts) == "table" then
			format_opts._todo_hierarchy_state = M.picker_hierarchy_ui_state
		end
	end
	return M.picker_hierarchy_ui_state
end

function M.toggle_todo_status_line(todo)
	if type(todo) ~= "table" then
		return nil
	end
	local next_status = config.STATUS_NEXT[todo.status] or config.STATUS_TODO
	local today_date = utils.today()
	todo.status = next_status
	todo.created = next_status == config.STATUS_TODO and today_date or (todo.created or today_date)
	todo.completed = next_status == config.STATUS_DONE and today_date or nil
	return todo
end

function M.toggle_todo_priority_line(todo)
	if type(todo) ~= "table" then
		return nil
	end
	todo.priority = config.PRIORITY_NEXT[todo.priority] or config.PRIORITY_LOW
	return todo
end

function M.picker_current_item(picker, item)
	if picker and picker.current then
		return picker:current({ resolve = false }) or item
	end
	return item
end

function M.picker_selected_items(picker, item)
	if picker and picker.selected then
		return picker:selected({ fallback = true }) or {}
	end
	return item and { item } or {}
end

function M.apply_to_selected_todos(picker, item, mutator)
	local changed = false
	local selected = M.picker_selected_items(picker, item)
	if #selected == 0 then
		local current_item = M.picker_current_item(picker, item)
		if current_item and current_item.todo_id and not current_item.todo_is_tag_header then
			selected = { current_item }
		else
			return
		end
	end

	local current_item = M.picker_current_item(picker, item)
	local focus_key = M.get_focus_key_for_item(current_item) or M.get_focus_key_for_item(item)

	local seen = {}
	for _, it in ipairs(selected) do
		if it.todo_id and not it.todo_is_tag_header and not seen[it.todo_id] then
			seen[it.todo_id] = true
			changed = store.update_todo_by_id(it.todo_id, mutator) or changed
		end
	end

	if changed then
		vim.schedule(function()
			M.refresh_picker_items(picker, { focus_key = focus_key })
		end)
	end
end

function M.picker_delete_todos(picker, item)
	local unique_items = {}
	local seen = {}
	for _, it in ipairs(M.picker_selected_items(picker, item)) do
		if it and it.todo_id and not it.todo_is_tag_header and not seen[it.todo_id] then
			seen[it.todo_id] = true
			unique_items[#unique_items + 1] = it
		end
	end

	if #unique_items == 0 then
		return
	end

	local ui = require("todo-picker.ui")
	if not ui.confirm_delete_todos(unique_items) then
		return
	end

	local changed = false
	for _, it in ipairs(unique_items) do
		if store.delete_todo_by_id(it.todo_id) then
			changed = true
		end
	end

	if changed then
		M.refresh_picker_items(picker, { focus_key = nil })
	end
end

function M.picker_open_source(picker, item)
	local selected = M.picker_selected_items(picker, item)
	local target = selected[1] or item
	if not target or not target.todo_id or target.todo_is_tag_header then
		return
	end

	local store_obj = store.load_store()
	local idx = store.find_todo_bucket(store_obj, target.todo_id)
	if not idx then
		return
	end
	store.ensure_todo_source(idx.todo)
	local file, lnum = markdown.resolve_source(idx.todo)
	if not file then
		utils.notify_todo("Source not found for this todo", vim.log.levels.WARN)
		return
	end

	if picker and picker.close then
		picker:close()
	end
	utils.open_source_at(file, lnum or 1)
end

function M.picker_open_reference(picker, item)
	local selected = M.picker_selected_items(picker, item)
	local target = selected[1] or item
	if not target or not target.todo_id or target.todo_is_tag_header then
		return
	end

	local store_obj = store.load_store()
	local idx = store.find_todo_bucket(store_obj, target.todo_id)
	if not idx then
		return
	end

	local file, lnum = markdown.resolve_reference(idx.todo, store_obj)
	if not file or not lnum then
		utils.notify_todo("Reference not found for this todo", vim.log.levels.WARN)
		return
	end

	if picker and picker.close then
		picker:close()
	end
	utils.open_source_at(file, lnum)
end

function M.picker_open_parent_detail(picker, item)
	local target = M.picker_current_item(picker, item)
	if not target then
		return
	end

	local store_obj = store.load_store()
	local parent_id = nil

	if target.todo_id then
		local bucket = store.find_todo_bucket(store_obj, target.todo_id)
		if bucket and bucket.todo then
			parent_id = bucket.todo.parent_id
		end
	end

	if (not parent_id or parent_id == "" or parent_id:match("^tag:")) and target.todo_parent_id then
		if not target.todo_parent_id:match("^tag:") then
			parent_id = target.todo_parent_id
		end
	end

	if not parent_id or parent_id == "" or parent_id == "independent" or parent_id:match("^tag:") then
		utils.notify_todo("This todo has no parent todo", vim.log.levels.WARN)
		return
	end

	local parent_item = store.get_todo_item_by_id(parent_id)
	if not parent_item and store_obj and store_obj.todos then
		for _, t in ipairs(store_obj.todos) do
			if t.id == parent_id or t.title == parent_id then
				parent_item = store.build_item_from_todo(t)
				break
			end
		end
	end

	if not parent_item then
		utils.notify_todo("Parent todo not found", vim.log.levels.WARN)
		return
	end

	local ui = require("todo-picker.ui")
	ui.open_todo_detail(picker, parent_item, {
		start_zone = "log",
		start_insert = false,
		picker_context = M.capture_picker_reopen_context(picker, target),
	})
end

function M.picker_create_task_below(picker, item)
	local target = M.picker_current_item(picker, item)
	local ui = require("todo-picker.ui")
	if not target or target.todo_is_empty_state then
		ui.open_new_todo_draft(picker, M.capture_picker_reopen_context(picker, target), {
			title = "",
			parent_id = nil,
			create_reference = false,
		})
		return
	end

	local format_opts = picker.opts._todo_format_opts or {}
	local current_mode = M.get_group_by_mode(format_opts)

	local inherited_labels = {}
	local inherited_extra_fields = {}
	local parent_id = nil

	if current_mode == "tag" then
		if target.todo_is_tag_header then
			if target.todo_text ~= "Untagged" then
				inherited_labels = { target.todo_text }
			end
		else
			inherited_labels = vim.deepcopy(target.todo_labels or {})
			inherited_extra_fields = vim.deepcopy(target.todo_extra_fields or {})
		end
	elseif current_mode == "parent" then
		if not target.todo_is_tag_header and target.todo_id ~= "independent" then
			parent_id = target.todo_parent_id
			if parent_id == "independent" then
				parent_id = nil
			end
			inherited_extra_fields = vim.deepcopy(target.todo_extra_fields or {})
		end
	else
		-- Global order mode: inherit both (original behavior)
		if not target.todo_is_tag_header and target.todo_id ~= "independent" then
			inherited_labels = vim.deepcopy(target.todo_labels or {})
			inherited_extra_fields = vim.deepcopy(target.todo_extra_fields or {})
			parent_id = target.todo_parent_id
			if parent_id == "independent" then
				parent_id = nil
			end
		end
	end

	ui.open_new_todo_draft(picker, M.capture_picker_reopen_context(picker, target), {
		title = "",
		parent_id = parent_id,
		create_reference = false,
		labels = inherited_labels,
		extra_fields = inherited_extra_fields,
	})
end

function M.picker_create_subtask(picker, item)
	local target = M.picker_current_item(picker, item)
	if target and (target.todo_is_tag_header or target.todo_id == "independent") then
		utils.notify_todo("Cannot create a subtask on a virtual header", vim.log.levels.WARN)
		return
	end
	local ui = require("todo-picker.ui")
	if not target or target.todo_is_empty_state or not target.todo_id then
		ui.open_new_todo_draft(picker, M.capture_picker_reopen_context(picker, target), {
			title = "",
			parent_id = nil,
			create_reference = false,
		})
		return
	end

	local inherited_labels = vim.deepcopy(target.todo_labels or {})
	local inherited_extra_fields = vim.deepcopy(target.todo_extra_fields or {})

	ui.open_new_todo_draft(picker, M.capture_picker_reopen_context(picker, target), {
		title = "",
		parent_id = target.todo_id,
		create_reference = false,
		labels = inherited_labels,
		extra_fields = inherited_extra_fields,
	})
end

function M.picker_prompt_relationship(picker, item, mode)
	local source = M.picker_current_item(picker, item)
	if source and source.todo_is_tag_header then
		utils.notify_todo("Cannot establish relationships for tag headers", vim.log.levels.WARN)
		return
	end
	if not source or not source.todo_id then
		return
	end

	local source_id = source.todo_id
	local source_title = source.todo_text or source.text or "Untitled task"
	local return_context = M.capture_picker_reopen_context(picker, source)

	if picker and not picker.closed and picker.close then
		picker:close()
	end

	local relation_picker_opts = M.get_todo_picker_opts({
		title = string.format("Relationship: %s -> pick second todo", source_title),
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
		if not target or not target.todo_id or target.todo_is_tag_header then
			return
		end

		local target_id = target.todo_id
		local target_title = target.todo_text or target.text or "Untitled task"
		if target_id == source_id then
			utils.notify_todo("Pick a different todo to define a relationship", vim.log.levels.WARN)
			return
		end

		if rel_picker and not rel_picker.closed and rel_picker.close then
			rel_picker:close()
		end

		local function apply_choice(choice)
			if not choice then
				M.reopen_picker_from_context(return_context)
				return
			end

			local ok, err, changed_child_id
			if choice.kind == "unlink_pair" then
				ok, err, changed_child_id = store.unlink_relationship_between(source_id, target_id)
			else
				ok, err = store.set_todo_parent_relationship(choice.child_id, choice.parent_id)
			end
			if not ok then
				utils.notify_todo(err or "Could not update relationship", vim.log.levels.WARN)
			else
				utils.notify_todo("Relationship updated")
				return_context.focus_key = "id:" .. (changed_child_id or choice.child_id or source_id)
			end

			M.reopen_picker_from_context(return_context)
		end

		if mode == "source_child" then
			apply_choice({
				label = string.format('Make "%s" a child of "%s"', source_title, target_title),
				child_id = source_id,
				parent_id = target_id,
			})
			return
		end

		if mode == "source_parent" then
			apply_choice({
				label = string.format('Make "%s" a child of "%s"', target_title, source_title),
				child_id = target_id,
				parent_id = source_id,
			})
			return
		end

		local choices = {
			{
				label = string.format('Make "%s" a child of "%s"', source_title, target_title),
				child_id = source_id,
				parent_id = target_id,
			},
			{
				label = string.format('Make "%s" a child of "%s"', target_title, source_title),
				child_id = target_id,
				parent_id = source_id,
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
		}, apply_choice)
	end

	local relation_picker = Snacks.picker(relation_picker_opts)
	if relation_picker then
		vim.schedule(function()
			M.restore_picker_focus(relation_picker, "id:" .. source_id)
		end)
	end
end

function M.picker_toggle_subtasks(picker, item)
	if M.is_flat_order_enabled(picker and picker.opts and picker.opts._todo_format_opts) then
		return
	end

	local state = M.get_picker_hierarchy_state(picker)
	if not state or not item then
		return
	end
	local target_id = item.todo_id
	if not target_id and item.todo_parent_id then
		target_id = item.todo_parent_id
	end
	if not target_id then
		return
	end
	local is_tag = (item.todo_is_tag_header == true) or (target_id and target_id:match("^tag:"))
	if not is_tag then
		local store_obj = store.load_store()
		local index = M.get_todo_hierarchy_index(store_obj)
		if (index.parent_to_child_count[target_id] or 0) == 0 then
			return
		end
	end
	local current_item = M.picker_current_item(picker, item)
	state.collapsed_by_id[target_id] = not state.collapsed_by_id[target_id]
	local focus_key = M.get_focus_key_for_item(current_item)
	if state.collapsed_by_id[target_id] then
		focus_key = "id:" .. target_id
	end
	M.refresh_picker_items(picker, { focus_key = focus_key })
end

function M.picker_toggle_all_subtasks(picker)
	if M.is_flat_order_enabled(picker and picker.opts and picker.opts._todo_format_opts) then
		return
	end

	local state = M.get_picker_hierarchy_state(picker)
	if not state then
		return
	end
	local current_item = M.picker_current_item(picker, nil)
	state.collapse_all = not state.collapse_all
	local focus_key = M.get_focus_key_for_item(current_item)
	if state.collapse_all and current_item and current_item.todo_parent_id and current_item.todo_parent_id ~= "" then
		focus_key = "id:" .. current_item.todo_parent_id
	end
	M.refresh_picker_items(picker, { focus_key = focus_key })
end

-- Filter functions removed

function M.picker_toggle_order_mode(picker, item)
	if not picker or not picker.opts then
		return
	end

	local format_opts = picker.opts._todo_format_opts or {}
	local current_mode = M.get_group_by_mode(format_opts)
	local next_mode
	if current_mode == "none" then
		next_mode = "parent"
	elseif current_mode == "parent" then
		next_mode = "tag"
	else
		next_mode = "none"
	end

	format_opts.group_by = next_mode
	format_opts.flat_order = (next_mode == "none")
	picker.opts._todo_format_opts = format_opts

	local current_item = M.picker_current_item(picker, item)
	local focus_key = M.get_focus_key_for_item(current_item) or M.get_focus_key_for_item(item)
	M.refresh_picker_items(picker, { focus_key = focus_key })
end

function M.picker_toggle_done_visibility(picker, item)
	if not picker or not picker.opts then
		return
	end

	local format_opts = picker.opts._todo_format_opts or {}
	if format_opts.only_done == true then
		return
	end

	local mode = M.get_done_visibility_mode(format_opts)
	if mode == "recent" then
		mode = "hide"
	elseif mode == "hide" then
		mode = "all"
	else
		mode = "recent"
	end

	format_opts.done_visibility = mode
	format_opts.include_done = nil
	format_opts.apply_done_retention = nil
	picker.opts._todo_format_opts = format_opts

	local current_item = M.picker_current_item(picker, item)
	local focus_key = M.get_focus_key_for_item(current_item) or M.get_focus_key_for_item(item)
	M.refresh_picker_items(picker, { focus_key = focus_key })
end

function M.capture_picker_reopen_context(picker, fallback_item)
	if not picker then
		return nil
	end
	local current_item = picker.current and picker:current({ resolve = false }) or fallback_item
	local focus_key = M.get_focus_key_for_item(current_item) or M.get_focus_key_for_item(fallback_item)
	return {
		picker = picker,
		focus_key = focus_key,
		reopen_opts = vim.deepcopy((picker.opts and picker.opts._todo_format_opts) or {}),
		hierarchy_state = vim.deepcopy(M.picker_hierarchy_ui_state or {
			collapsed_by_id = {},
			collapse_all = false,
		}),
	}
end

function M.open_todo_picker(opts)
	local picker = Snacks.picker(M.get_todo_picker_opts(opts or {}))
	if picker then
		vim.schedule(function()
			local current = picker:current()
			if current and not is_selectable(current) then
				for candidate, idx in picker:iter() do
					if is_selectable(candidate) then
						picker.list:view(idx)
						break
					end
				end
			end
		end)
	end
	return picker
end

function M.reopen_picker_from_context(context)
	if not context then
		return
	end

	local reopen_opts = vim.deepcopy(context.reopen_opts or {})
	if context.hierarchy_state then
		reopen_opts._todo_hierarchy_state = vim.deepcopy(context.hierarchy_state)
	end

	local new_picker = M.open_todo_picker(reopen_opts)
	if context.focus_key and new_picker then
		vim.schedule(function()
			M.restore_picker_focus(new_picker, context.focus_key)
		end)
	end

	local picker = context.picker
	if picker and not picker.closed and picker.close then
		picker:close()
	end
end


function M.get_todo_picker_opts(opts)
	opts = opts or {}
	M.picker_hierarchy_ui_state = vim.deepcopy(opts._todo_hierarchy_state or {
		collapsed_by_id = {},
		collapse_all = false,
	})

	local UI = config.options.ui
	local message_indent = UI.picker.message_indent
	local items = M.collect_picker_items(opts)

	return {
		title = " TODO Picker (Type #tag for tags, @parent for subtasks) ",
		_todo_format_opts = opts,
		items = items,
		focus = "list",
		confirm = function(p, item)
			require("todo-picker.ui").open_todo_detail(p, item)
		end,
		actions = {
			todo_toggle_status = function(picker, item)
				M.apply_to_selected_todos(picker, item, M.toggle_todo_status_line)
			end,
			todo_toggle_priority = function(picker, item)
				M.apply_to_selected_todos(picker, item, M.toggle_todo_priority_line)
			end,
			todo_delete = function(picker, item)
				M.picker_delete_todos(picker, item)
			end,
			todo_open_source = function(picker, item)
				M.picker_open_source(picker, item)
			end,
			todo_open_reference = function(picker, item)
				M.picker_open_reference(picker, item)
			end,
			todo_open_parent = function(picker, item)
				M.picker_open_parent_detail(picker, item)
			end,
			todo_create_task = function(picker, item)
				M.picker_create_task_below(picker, item)
			end,
			todo_create_subtask = function(picker, item)
				M.picker_create_subtask(picker, item)
			end,
			todo_relationship = function(picker, item)
				M.picker_prompt_relationship(picker, item, nil)
			end,
			todo_toggle_subtasks = function(picker, item)
				M.picker_toggle_subtasks(picker, item)
			end,
			todo_toggle_all_subtasks = function(picker)
				M.picker_toggle_all_subtasks(picker)
			end,
			todo_toggle_help = function(picker)
				M.toggle_picker_help(picker)
			end,

			todo_toggle_order_mode = function(picker, item)
				M.picker_toggle_order_mode(picker, item)
			end,
			todo_toggle_done_visibility = function(picker, item)
				M.picker_toggle_done_visibility(picker, item)
			end,
			todo_list_down = function(picker)
				local current_item = picker:current()
				local current_idx = nil
				local items_by_idx = {}
				local max_idx = 0
				for candidate, idx in picker:iter() do
					items_by_idx[idx] = candidate
					if candidate == current_item then
						current_idx = idx
					end
					if idx > max_idx then
						max_idx = idx
					end
				end
				if not current_idx then return end
				local next_idx = current_idx + 1
				while next_idx <= max_idx do
					local item = items_by_idx[next_idx]
					if is_selectable(item) then
						picker.list:view(next_idx)
						return
					end
					next_idx = next_idx + 1
				end
			end,
			todo_list_up = function(picker)
				local current_item = picker:current()
				local current_idx = nil
				local items_by_idx = {}
				for candidate, idx in picker:iter() do
					items_by_idx[idx] = candidate
					if candidate == current_item then
						current_idx = idx
					end
				end
				if not current_idx then return end
				local prev_idx = current_idx - 1
				while prev_idx >= 1 do
					local item = items_by_idx[prev_idx]
					if is_selectable(item) then
						picker.list:view(prev_idx)
						return
					end
					prev_idx = prev_idx - 1
				end
			end,
			todo_tab_next_group = function(picker)
				local current_item = picker:current()
				local current_idx = nil
				local items_by_idx = {}
				local group_starts = {}
				for candidate, idx in picker:iter() do
					items_by_idx[idx] = candidate
					if candidate == current_item then
						current_idx = idx
					end
					local is_start = candidate.todo_is_tag_header == true
						or candidate.todo_id == "independent"
						or (candidate.todo_flat_order == false and candidate.todo_depth == 0 and not candidate.todo_is_empty_state)
					if is_start then
						table.insert(group_starts, idx)
					end
				end
				if #group_starts == 0 then
					picker:action("list_down")
					return
				end

				local current_group_idx = nil
				if current_idx then
					for i, gs_idx in ipairs(group_starts) do
						if gs_idx <= current_idx then
							current_group_idx = i
						end
					end
				end

				local next_group_idx = 1
				if current_group_idx then
					next_group_idx = current_group_idx + 1
					if next_group_idx > #group_starts then
						next_group_idx = 1
					end
				end

				local target_idx = group_starts[next_group_idx]
				local max_idx = 0
				for _, idx in ipairs(group_starts) do
					if idx > max_idx then max_idx = idx end
				end
				while target_idx <= max_idx + 10 do
					local item = items_by_idx[target_idx]
					if is_selectable(item) then
						picker.list:view(target_idx)
						return
					end
					target_idx = target_idx + 1
				end
			end,
			todo_tab_prev_group = function(picker)
				local current_item = picker:current()
				local current_idx = nil
				local items_by_idx = {}
				local group_starts = {}
				for candidate, idx in picker:iter() do
					items_by_idx[idx] = candidate
					if candidate == current_item then
						current_idx = idx
					end
					local is_start = candidate.todo_is_tag_header == true
						or candidate.todo_id == "independent"
						or (candidate.todo_flat_order == false and candidate.todo_depth == 0 and not candidate.todo_is_empty_state)
					if is_start then
						table.insert(group_starts, idx)
					end
				end
				if #group_starts == 0 then
					picker:action("list_up")
					return
				end

				local current_group_idx = nil
				if current_idx then
					for i, gs_idx in ipairs(group_starts) do
						if gs_idx <= current_idx then
							current_group_idx = i
						end
					end
				end

				local prev_group_idx = #group_starts
				if current_group_idx then
					prev_group_idx = current_group_idx - 1
					if prev_group_idx < 1 then
						prev_group_idx = #group_starts
					end
				end

				local target_idx = group_starts[prev_group_idx]
				while target_idx <= #items_by_idx + 10 do
					local item = items_by_idx[target_idx]
					if is_selectable(item) then
						picker.list:view(target_idx)
						return
					end
					target_idx = target_idx + 1
				end
			end,
			todo_input_escape_to_list = function(picker)
				if vim.fn.mode():sub(1, 1) == "i" then
					vim.cmd.stopinsert()
				end
				if picker and picker.focus then
					picker:focus("list")
				end
			end,
		},
		format = function(item)
			if item.todo_is_empty_state then
				return {
					{ tree_prefix, "Comment" },
					{ "+ New TODO", "SnacksPickerKeymapLhs" },
				}
			end

			local status_icons = {
				[config.STATUS_TODO] = config.ICONS.status.TODO,
				[config.STATUS_BLOCKED] = config.ICONS.status.BLOCKED,
				[config.STATUS_DOING] = config.ICONS.status.DOING,
				[config.STATUS_PEER_REVIEW] = config.ICONS.status.PEER_REVIEW,
				[config.STATUS_DONE] = config.ICONS.status.DONE,
			}

			local priority_badges = {
				[config.PRIORITY_HIGH] = config.ICONS.priority.HIGH,
				[config.PRIORITY_MEDIUM] = config.ICONS.priority.MEDIUM,
				[config.PRIORITY_LOW] = config.ICONS.priority.LOW,
			}

			local priority = item.todo_priority or config.PRIORITY_LOW
			local priority_hl = config.PRIORITY_HL[priority] or "NonText"
			local priority_badge_char = priority_badges[priority] or " "

			local title_hl = "Normal"
			if item.todo_is_tag_header or item.todo_id == "independent" then
				title_hl = config.TAG_HEADER_HL
			else
				local status = item.todo_status or -1
				local status_color = config.STATUS_COLOR[status] or "Normal"
				title_hl = utils.title_highlight_for_status(item.todo_status_value, status_color)
			end

			local depth = item.todo_depth or 0
			local is_child = depth > 0
			local has_children = item.todo_has_children == true
			local is_collapsed = item.todo_collapsed == true
			local tree_prefix = UI.picker.tree.base

			if has_children then
				local depth_indent = string.rep(UI.picker.tree.indent_step, is_child and depth or 0)
				tree_prefix = depth_indent .. (is_collapsed and " " or " ")
			elseif is_child then
				local depth_indent = string.rep(UI.picker.tree.indent_step, depth)
				tree_prefix = depth_indent .. "  "
			end

			local progress_badge = item.todo_progress_badge or ""
			if progress_badge ~= "" then
				progress_badge = UI.picker.progress_sep .. progress_badge
			end

			local group_by = item.todo_group_by or "parent"
			local show_parent_hint = (item.todo_flat_order or group_by == "tag") and not item.todo_is_tag_header
			local show_tags_hint = (item.todo_flat_order or group_by == "parent") and not item.todo_is_tag_header

			local parent_hint = ""
			if show_parent_hint and item.todo_parent_title and item.todo_parent_title ~= "" then
				parent_hint = " " .. config.ICONS.parent .. " " .. item.todo_parent_title
			end

			local tags_hint = ""
			if show_tags_hint and item.todo_labels and #item.todo_labels > 0 then
				local label_tokens = {}
				for _, label in ipairs(item.todo_labels) do
					label_tokens[#label_tokens + 1] = config.ICONS.tag .. " " .. tostring(label)
				end
				tags_hint = " " .. table.concat(label_tokens, " ")
			end

			local display_text = item.todo_text or ""
			if item.todo_is_tag_header then
				return {
					{ config.ICONS.tag .. " ", config.TAG_HEADER_HL },
					{ display_text, config.TAG_HEADER_HL },
					{ progress_badge, "Comment" },
				}
			elseif item.todo_has_children and (depth == 0) then
				return {
					{ tree_prefix, "Comment" },
					{ config.ICONS.parent .. " ", config.TAG_HEADER_HL },
					{ display_text, config.TAG_HEADER_HL },
					{ progress_badge, "Comment" },
				}
			else
				local status_icon = status_icons[item.todo_status_value] or ""
				local text_color = "Normal"
				if item.todo_status_value == config.STATUS_DONE then
					text_color = "Comment"
				end

				local meta_segments = {}
				if priority_badge_char ~= " " then
					table.insert(meta_segments, { priority_badge_char, priority_hl })
				end
				if parent_hint ~= "" then
					table.insert(meta_segments, { parent_hint, config.PARENT_HINT_HL })
				end
				if tags_hint ~= "" then
					table.insert(meta_segments, { tags_hint, config.PARENT_HINT_HL })
				end
				if progress_badge ~= "" then
					table.insert(meta_segments, { progress_badge, "Comment" })
				end

				local result = {
					{ tree_prefix, "Comment" },
					{ status_icon .. " ", title_hl },
					{ display_text, text_color },
				}

				if #meta_segments > 0 then
					table.insert(result, { "   ", "Normal" })
					for s_idx, seg in ipairs(meta_segments) do
						table.insert(result, seg)
						if s_idx < #meta_segments then
							table.insert(result, { " ", "Normal" })
						end
					end
				end

				return result
			end
		end,
		live = false,
		on_close = function(picker)
			M.close_picker_help(picker)
		end,
		layout = (function()
			local l = vim.deepcopy(UI.picker.layout)
			if l and l.layout then
				l.layout.backdrop = 60
			end
			return l
		end)(),
		win = {
			wo = {
				winhighlight = "Normal:Normal,FloatBorder:TodoTransparentBorder,FloatTitle:TodoFloatTitle",
			},
			input = {
				wo = {
					winhighlight = "Normal:Normal,FloatBorder:TodoTransparentBorder,FloatTitle:TodoFloatTitle",
				},
				keys = {
					["<Esc>"] = {
						"todo_input_escape_to_list",
						mode = { "i" },
						desc = "leave input and focus todo list",
					},
					["?"] = { "todo_toggle_help", mode = { "n" }, desc = "show picker help" },
					["/"] = { "toggle_focus", mode = { "n" }, desc = "toggle input/list focus" },
					["D"] = { "todo_delete", mode = { "n" }, desc = "delete todo" },
					["<Tab>"] = { "todo_tab_next_group", mode = { "n" }, desc = "next group" },
					["<S-Tab>"] = { "todo_tab_prev_group", mode = { "n" }, desc = "previous group" },
					["s"] = { "todo_toggle_status", mode = { "n" }, desc = "toggle todo status" },
					["p"] = { "todo_toggle_priority", mode = { "n" }, desc = "toggle todo priority" },
					["P"] = { "todo_open_parent", mode = { "n" }, desc = "open parent todo details" },
					["g"] = { "todo_toggle_order_mode", mode = { "n" }, desc = "toggle grouped/global order" },
					["x"] = {
						"todo_toggle_done_visibility",
						mode = { "n" },
						desc = "cycle done visibility (hide/recent/all)",
					},
					["r"] = { "todo_relationship", mode = { "n" }, desc = "set parent/child relationship" },
					["z"] = { "todo_toggle_subtasks", mode = { "n" }, desc = "toggle subtasks" },
					["Z"] = { "todo_toggle_all_subtasks", mode = { "n" }, desc = "toggle all subtasks" },
				},
			},
			list = {
				wo = {
					winhighlight = "Normal:Normal,FloatBorder:TodoTransparentBorder,FloatTitle:TodoFloatTitle",
				},
				keys = {
					["?"] = { "todo_toggle_help", mode = { "n" }, desc = "show picker help" },
					["/"] = { "toggle_focus", mode = { "n" }, desc = "focus search input" },
					["i"] = { "focus_input", mode = { "n" }, desc = "focus search input" },
					["D"] = { "todo_delete", mode = { "n" }, desc = "delete todo" },
					["j"] = { "todo_list_down", mode = { "n" }, desc = "next todo" },
					["k"] = { "todo_list_up", mode = { "n" }, desc = "previous todo" },
					["<Down>"] = { "todo_list_down", mode = { "n" }, desc = "next todo" },
					["<Up>"] = { "todo_list_up", mode = { "n" }, desc = "previous todo" },
					["<Tab>"] = { "todo_tab_next_group", mode = { "n" }, desc = "next group" },
					["<S-Tab>"] = { "todo_tab_prev_group", mode = { "n" }, desc = "previous group" },
					["s"] = { "todo_toggle_status", mode = { "n" }, desc = "toggle todo status" },
					["P"] = { "todo_open_parent", mode = { "n" }, desc = "open parent todo details" },
					["p"] = { "todo_toggle_priority", mode = { "n" }, desc = "toggle todo priority" },
					["g"] = { "todo_toggle_order_mode", mode = { "n" }, desc = "toggle grouped/global order" },
					["x"] = {
						"todo_toggle_done_visibility",
						mode = { "n" },
						desc = "cycle done visibility (hide/recent/all)",
					},
					["r"] = { "todo_relationship", mode = { "n" }, desc = "set parent/child relationship" },
					["t"] = { "todo_create_task", mode = { "n" }, desc = "create task below current" },
					["a"] = { "todo_create_subtask", mode = { "n" }, desc = "create subtask for current" },
					["e"] = { "todo_open_source", mode = { "n" }, desc = "open todo source" },
					["m"] = { "todo_open_reference", mode = { "n" }, desc = "open markdown reference" },
					["z"] = { "todo_toggle_subtasks", mode = { "n" }, desc = "toggle subtasks" },
					["Z"] = { "todo_toggle_all_subtasks", mode = { "n" }, desc = "toggle all subtasks" },
				},
				wo = {
					wrap = true,
					linebreak = true,
					breakindent = true,
					breakindentopt = string.format("shift:%d,min:%d", message_indent, message_indent),
					showbreak = " ",
				},
			},
		},
		matcher = { sort_empty = true },
		sort = {
			fields = {
				"todo_grouped_order:asc",
				"todo_status:asc",
				"todo_completed_sort_effective:asc",
				"todo_priority_sort_effective:asc",
				"todo_created_sort:asc",
				"score:desc",
				"idx",
			},
		},
	}
end

return M
