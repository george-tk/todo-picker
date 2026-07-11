local M = {}

local config = require("todo-picker.config")
local utils = require("todo-picker.utils")
local store = require("todo-picker.store")
local ui = require("todo-picker.ui")

M.board_state = {
	board_win = nil,
	group_by = "tag", -- Default grouping is tag
	windows = {}, -- map of status_name -> win_id
	buffers = {}, -- map of status_name -> buf_id
	line_mappings = {}, -- map of status_name -> { [line_num] = todo_item }
	lane_start_lines = {}, -- list of line numbers where each lane begins in all buffers
	active_todo_id = nil,
	active_status = nil,
	hl_ns = vim.api.nvim_create_namespace("todo_kanban_cursor"),
	rendering = false,
}

-- Helper: Grouping by parent
local function get_parent_groups(todos)
	local by_id = {}
	for _, t in ipairs(todos) do
		by_id[t.id] = t
	end

	local groups = {}
	local independent = {
		title = "Independent Tasks",
		id = "independent",
		is_virtual = true,
		todos = {},
	}

	-- Map parent_id to children list
	local children = {}
	for _, t in ipairs(todos) do
		if t.parent_id and by_id[t.parent_id] then
			children[t.parent_id] = children[t.parent_id] or {}
			table.insert(children[t.parent_id], t)
		end
	end

	-- Create groups
	for _, t in ipairs(todos) do
		if not t.parent_id or not by_id[t.parent_id] then
			if children[t.id] then
				local g = {
					title = t.title,
					id = t.id,
					is_virtual = false,
					todos = { t }, -- parent itself
				}
				for _, child in ipairs(children[t.id]) do
					table.insert(g.todos, child)
				end
				table.insert(groups, g)
			else
				table.insert(independent.todos, t)
			end
		end
	end

	if #independent.todos > 0 then
		table.insert(groups, 1, independent)
	end

	return groups
end

-- Helper: Grouping by tag
local function get_tag_groups(todos)
	local groups = {}
	local tag_map = {}
	local untagged = {
		title = "Untagged",
		id = "untagged",
		is_virtual = true,
		todos = {},
	}

	for _, t in ipairs(todos) do
		if t.labels and #t.labels > 0 then
			for _, label in ipairs(t.labels) do
				local clean = tostring(label):lower()
				if clean ~= "" then
					if not tag_map[clean] then
						tag_map[clean] = {
							title = label,
							id = "tag:" .. clean,
							is_virtual = true,
							todos = {},
						}
					end
					table.insert(tag_map[clean].todos, t)
				end
			end
		else
			table.insert(untagged.todos, t)
		end
	end

	local sorted_keys = {}
	for k, _ in pairs(tag_map) do
		table.insert(sorted_keys, k)
	end
	table.sort(sorted_keys)

	for _, k in ipairs(sorted_keys) do
		table.insert(groups, tag_map[k])
	end

	if #untagged.todos > 0 then
		table.insert(groups, 1, untagged)
	end

	return groups
end

-- Helper: Flat (No) grouping
local function get_flat_groups(todos)
	return {
		{
			title = "All Tasks",
			id = "all",
			is_virtual = true,
			todos = todos,
		},
	}
end

-- Helper: Get current active column name
local function get_current_column_name()
	local cur_win = vim.api.nvim_get_current_win()
	for col_name, win in pairs(M.board_state.windows) do
		if win == cur_win then
			return col_name
		end
	end
	return nil
end

-- Helper: Save cursor position relative to focused todo card
local function save_cursor_position()
	local col_name = get_current_column_name()
	if not col_name then
		return nil, nil
	end

	local win = M.board_state.windows[col_name]
	if not win or not vim.api.nvim_win_is_valid(win) then
		return nil, nil
	end

	local cursor = vim.api.nvim_win_get_cursor(win)
	local line = cursor[1]
	local todo = M.board_state.line_mappings[col_name][line]

	if todo then
		return todo.id, col_name
	end
	return nil, col_name
end

-- Helper: Restore cursor focus to the specified todo
local function restore_cursor_position(todo_id, fallback_col)
	if not todo_id then
		if fallback_col and M.board_state.windows[fallback_col] then
			local win = M.board_state.windows[fallback_col]
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_set_current_win(win)
				pcall(vim.api.nvim_win_set_cursor, win, { 1, 2 })
			end
		end
		return
	end

	local found_col = nil
	local found_line = nil

	if fallback_col and M.board_state.line_mappings[fallback_col] then
		for l, todo in pairs(M.board_state.line_mappings[fallback_col]) do
			if todo and todo.id == todo_id then
				found_col = fallback_col
				found_line = l
				break
			end
		end
	end

	if not found_line then
		for col, mappings in pairs(M.board_state.line_mappings) do
			for l, todo in pairs(mappings) do
				if todo and todo.id == todo_id then
					found_col = col
					found_line = l
					break
				end
			end
			if found_line then
				break
			end
		end
	end

	if found_col and found_line then
		local win = M.board_state.windows[found_col]
		if not win or not vim.api.nvim_win_is_valid(win) then
			-- Scroll to make found_col visible
			local _, sorted_statuses = M.get_columns()
			local target_status_idx = nil
			for idx, s in ipairs(sorted_statuses) do
				if s.name == found_col then
					target_status_idx = idx
					break
				end
			end
			if target_status_idx and M.board_state.board_win and M.board_state.board_win:valid() then
				local board_w = vim.api.nvim_win_get_width(M.board_state.board_win.win)
				local board_h = vim.api.nvim_win_get_height(M.board_state.board_win.win)
				local visible_count = select(4, M.layout_columns(board_w))

				if target_status_idx < M.board_state.scroll_index then
					M.board_state.scroll_index = target_status_idx
				elseif target_status_idx >= M.board_state.scroll_index + visible_count then
					M.board_state.scroll_index = target_status_idx - visible_count + 1
				end

				M.recreate_column_windows(board_w, board_h, found_col)
				M.render_board()
				win = M.board_state.windows[found_col]
			end
		end

		if win and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_set_current_win(win)
			pcall(vim.api.nvim_win_set_cursor, win, { found_line, 2 })
		end
	end
end

-- Helper: Focus the first ticket of the entire board (top-leftmost card)
local function focus_first_ticket_on_board()
	local columns, sorted_statuses = M.get_columns()
	local target_col = nil
	local target_line = nil

	-- Scan status columns left-to-right to find the first occupied cell
	for _, col in ipairs(columns) do
		if col ~= "GROUPING" then
			local mappings = M.board_state.line_mappings[col] or {}
			local min_line = nil
			for l, todo in pairs(mappings) do
				if todo then
					if not min_line or l < min_line then
						min_line = l
					end
				end
			end
			if min_line then
				target_col = col
				target_line = min_line
				break
			end
		end
	end

	if target_col and target_line then
		local win = M.board_state.windows[target_col]
		if win and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_set_current_win(win)
			pcall(vim.api.nvim_win_set_cursor, win, { target_line, 2 })
		end
	end
end

-- Helper: Wrap text by display width
local function wrap_text(text, first_line_w, other_line_w)
	local lines = {}
	local current_line = ""
	local current_w = 0
	local target_w = first_line_w

	local words = {}
	for word in string.gmatch(text, "%S+") do
		table.insert(words, word)
	end

	if #words == 0 then
		return { "" }
	end

	for _, word in ipairs(words) do
		local word_w = vim.fn.strdisplaywidth(word)
		local space_w = (current_line == "") and 0 or 1

		if current_w + space_w + word_w <= target_w then
			if current_line == "" then
				current_line = word
				current_w = word_w
			else
				current_line = current_line .. " " .. word
				current_w = current_w + 1 + word_w
			end
		else
			if word_w > target_w then
				if current_line ~= "" then
					table.insert(lines, current_line)
					current_line = ""
					current_w = 0
					target_w = other_line_w
				end

				local chars = {}
				for c_idx = 1, vim.fn.strchars(word) do
					table.insert(chars, vim.fn.strcharpart(word, c_idx - 1, 1))
				end

				for _, char in ipairs(chars) do
					local char_w = vim.fn.strdisplaywidth(char)
					if current_w + char_w <= target_w then
						current_line = current_line .. char
						current_w = current_w + char_w
					else
						table.insert(lines, current_line)
						current_line = char
						current_w = char_w
						target_w = other_line_w
					end
				end
			else
				if current_line ~= "" then
					table.insert(lines, current_line)
				end
				current_line = word
				current_w = word_w
				target_w = other_line_w
			end
		end
	end

	if current_line ~= "" then
		table.insert(lines, current_line)
	end

	return lines
end

-- Helper: Render status column tickets for a lane (tickets are separate boxes, empty cell is blank)
local function render_column_lane(tasks, width, lane_height)
	local lines = {}
	local hls = {}
	local line_mappings = {}

	if #tasks == 0 then
		-- Return lane_height empty lines
		for pad = 1, lane_height do
			table.insert(lines, "")
		end
		return lines, hls, line_mappings
	end

	local inner_w = width - 4

	local priority_badges = {
		[config.PRIORITY_HIGH] = "●",
		[config.PRIORITY_MEDIUM] = "●",
		[config.PRIORITY_LOW] = " ",
	}

	for task_idx, todo in ipairs(tasks) do
		local priority_hl = config.PRIORITY_HL[todo.priority] or "NonText"
		local priority_badge = priority_badges[todo.priority] or " "
		local badge_w = vim.fn.strdisplaywidth(priority_badge .. " ")

		-- Determine status text highlight to apply to left border accent
		local status_hl = config.STATUS_COLOR[config.STATUS_SORT[todo.status] or 0] or "Normal"
		local text_hl = utils.title_highlight_for_status(todo.status, status_hl)

		-- Wrap title (wrap all lines to the same narrow width to align them)
		local wrapped_title_lines = wrap_text(todo.title, inner_w - badge_w, inner_w - badge_w)
		local start_line_idx = #lines + 1

		-- Card Top Border (uses Comment highlight group for a subtle look)
		table.insert(lines, "╭" .. string.rep("─", width - 2) .. "╮")
		table.insert(hls, { #lines - 1, 0, -1, "Comment" })
		line_mappings[#lines] = todo

		-- Card Body Lines (Title)
		for idx, tl in ipairs(wrapped_title_lines) do
			local text = "│ "
			local p_start, p_end
			if idx == 1 then
				p_start = #text
				text = text .. priority_badge
				p_end = #text
				text = text .. " "
			else
				text = text .. string.rep(" ", badge_w)
			end

			local t_start = #text
			text = text .. tl
			local t_end = #text

			local current_display_w = badge_w + vim.fn.strdisplaywidth(tl)
			local padding_len = math.max(0, inner_w - current_display_w)
			text = text .. string.rep(" ", padding_len) .. " │"

			table.insert(lines, text)
			local abs_line = #lines
			local line_len = #text

			-- Highlight left border character in status color, right in Comment, and body as Normal (dimmed Comment for completed items)
			local body_hl = "Normal"
			if todo.status == config.STATUS_DONE then
				body_hl = "Comment"
			end
			table.insert(hls, { abs_line - 1, 0, 3, text_hl })
			table.insert(hls, { abs_line - 1, 3, line_len - 3, body_hl })
			table.insert(hls, { abs_line - 1, line_len - 3, line_len, "Comment" })

			if idx == 1 and priority_badge ~= " " then
				table.insert(hls, { abs_line - 1, p_start, p_end, priority_hl })
			end

			line_mappings[abs_line] = todo
		end

		-- Add group-dependent sub-text (parent under tag mode, tags under parent mode)
		local sub_text = nil
		local group_by = M.board_state.group_by
		if group_by == "tag" then
			if todo.parent_id and todo.parent_id ~= "" then
				local title_by_id = M.board_state.title_by_id or {}
				local parent_title = title_by_id[todo.parent_id] or todo.parent_id
				sub_text = "[" .. parent_title .. "]"
			end
		elseif group_by == "parent" then
			if todo.labels and #todo.labels > 0 then
				local label_tokens = {}
				for _, label in ipairs(todo.labels) do
					table.insert(label_tokens, "#" .. tostring(label))
				end
				sub_text = table.concat(label_tokens, " ")
			end
		end

		if sub_text and sub_text ~= "" then
			local max_sub_w = inner_w - badge_w
			if vim.fn.strdisplaywidth(sub_text) > max_sub_w then
				local chars = {}
				for c_idx = 1, vim.fn.strchars(sub_text) do
					table.insert(chars, vim.fn.strcharpart(sub_text, c_idx - 1, 1))
				end
				local truncated = ""
				local truncated_w = 0
				for _, char in ipairs(chars) do
					local cw = vim.fn.strdisplaywidth(char)
					if truncated_w + cw + 3 <= max_sub_w then
						truncated = truncated .. char
						truncated_w = truncated_w + cw
					else
						break
					end
				end
				sub_text = truncated .. "..."
			end

			local text = "│ " .. string.rep(" ", badge_w) .. sub_text
			local current_display_w = badge_w + vim.fn.strdisplaywidth(sub_text)
			local padding_len = math.max(0, inner_w - current_display_w)
			text = text .. string.rep(" ", padding_len) .. " │"

			table.insert(lines, text)
			local abs_line = #lines
			local line_len = #text

			-- Highlight left border character in status color, right in Comment, and body as Comment
			table.insert(hls, { abs_line - 1, 0, 3, text_hl })
			table.insert(hls, { abs_line - 1, 3, line_len - 3, "Comment" })
			table.insert(hls, { abs_line - 1, line_len - 3, line_len, "Comment" })

			line_mappings[abs_line] = todo
		end

		-- Card Bottom Border (uses Comment highlight group for consistency)
		table.insert(lines, "╰" .. string.rep("─", width - 2) .. "╯")
		table.insert(hls, { #lines - 1, 0, -1, "Comment" })
		line_mappings[#lines] = todo

		-- 1-line gap after card if not the last card
		if task_idx < #tasks then
			table.insert(lines, "")
		end
	end

	-- Pad remaining rows to match lane_height
	local printed_height = #lines
	local group_padding = math.max(0, lane_height - printed_height)
	for pad = 1, group_padding do
		table.insert(lines, "")
	end

	return lines, hls, line_mappings
end

-- Helper: Smart navigation jumping between valid tickets like reading a book
local function smart_navigate_book(direction)
	local col_name = get_current_column_name()
	if not col_name then return end

	local win = vim.api.nvim_get_current_win()
	local cursor = vim.api.nvim_win_get_cursor(win)
	local curr_line = cursor[1]

	-- Get sorted statuses to define columns order
	local sorted_statuses = {}
	for status_name, rank in pairs(config.STATUS_SORT) do
		table.insert(sorted_statuses, { name = status_name, rank = rank })
	end
	table.sort(sorted_statuses, function(a, b)
		return a.rank < b.rank
	end)

	local cols = {}
	for _, s in ipairs(sorted_statuses) do
		table.insert(cols, s.name)
	end

	-- Get lane starts
	local lane_starts = M.board_state.lane_start_lines or {}
	if #lane_starts == 0 then return end

	local sorted_lane_starts = vim.deepcopy(lane_starts)
	table.sort(sorted_lane_starts)

	local g_buf = M.board_state.buffers["GROUPING"]
	if not g_buf or not vim.api.nvim_buf_is_valid(g_buf) then return end
	local total_lines = vim.api.nvim_buf_line_count(g_buf)

	-- Build 2D grid of tickets: grid[l_idx][c_idx] = { {col, line, id, lane, col_idx}, ... }
	local grid = {}
	local N = #sorted_lane_starts
	local C = #cols

	for l_idx = 1, N do
		grid[l_idx] = {}
		local start_line = sorted_lane_starts[l_idx]
		local end_line = total_lines
		if l_idx < N then
			end_line = sorted_lane_starts[l_idx + 1] - 4
		end

		for c_idx = 1, C do
			local col = cols[c_idx]
			grid[l_idx][c_idx] = {}
			local mappings = M.board_state.line_mappings[col] or {}
			local last_id = nil
			for l = start_line, end_line do
				local todo = mappings[l]
				if todo then
					if todo.id ~= last_id then
						table.insert(grid[l_idx][c_idx], {
							col = col,
							line = l,
							id = todo.id,
							lane = l_idx,
							col_idx = c_idx,
						})
						last_id = todo.id
					end
				else
					last_id = nil
				end
			end
		end
	end

	-- Determine current lane and column index
	local curr_lane = nil
	for l_idx = 1, N do
		local start_line = sorted_lane_starts[l_idx]
		local end_line = total_lines
		if l_idx < N then
			end_line = sorted_lane_starts[l_idx + 1] - 4
		end
		if curr_line >= start_line and curr_line <= end_line then
			curr_lane = l_idx
			break
		end
	end
	if not curr_lane then
		-- Fallback to closest lane
		local best_diff = 999999
		for l_idx = 1, N do
			local diff = math.abs(sorted_lane_starts[l_idx] - curr_line)
			if diff < best_diff then
				best_diff = diff
				curr_lane = l_idx
			end
		end
	end

	local curr_col_idx = nil
	for c_idx = 1, C do
		if cols[c_idx] == col_name then
			curr_col_idx = c_idx
			break
		end
	end
	if not curr_col_idx then return end

	-- Find active ticket index within current cell
	local curr_todo = (M.board_state.line_mappings[col_name] or {})[curr_line]
	local curr_ticket_idx = nil
	local cell_tickets = grid[curr_lane][curr_col_idx]

	if curr_todo then
		for i, t in ipairs(cell_tickets) do
			if t.id == curr_todo.id then
				curr_ticket_idx = i
				break
			end
		end
	end

	-- Fallback for ticket index
	if not curr_ticket_idx and #cell_tickets > 0 then
		local best_diff = 999999
		for i, t in ipairs(cell_tickets) do
			local diff = math.abs(t.line - curr_line)
			if diff < best_diff then
				best_diff = diff
				curr_ticket_idx = i
			end
		end
	end

	if not curr_ticket_idx then
		curr_ticket_idx = 1
	end

	-- Target coordinate holders
	local target_lane = nil
	local target_col_idx = nil
	local target_ticket_idx = nil

	if direction == "right" then
		-- 1. Search next columns in same lane
		for c = curr_col_idx + 1, C do
			if #grid[curr_lane][c] > 0 then
				target_lane = curr_lane
				target_col_idx = c
				target_ticket_idx = 1
				break
			end
		end
		-- 2. Search next lanes
		if not target_lane then
			for l = curr_lane + 1, N do
				for c = 1, C do
					if #grid[l][c] > 0 then
						target_lane = l
						target_col_idx = c
						target_ticket_idx = 1
						break
					end
				end
				if target_lane then break end
			end
		end
		-- 3. Wrap to beginning
		if not target_lane then
			for l = 1, N do
				for c = 1, C do
					if #grid[l][c] > 0 then
						target_lane = l
						target_col_idx = c
						target_ticket_idx = 1
						break
					end
				end
				if target_lane then break end
			end
		end

	elseif direction == "left" then
		-- 1. Search previous columns in same lane
		for c = curr_col_idx - 1, 1, -1 do
			if #grid[curr_lane][c] > 0 then
				target_lane = curr_lane
				target_col_idx = c
				target_ticket_idx = 1
				break
			end
		end
		-- 2. Search previous lanes
		if not target_lane then
			for l = curr_lane - 1, 1, -1 do
				for c = C, 1, -1 do
					if #grid[l][c] > 0 then
						target_lane = l
						target_col_idx = c
						target_ticket_idx = #grid[l][c]
						break
					end
				end
				if target_lane then break end
			end
		end
		-- 3. Wrap to end
		if not target_lane then
			for l = N, 1, -1 do
				for c = C, 1, -1 do
					if #grid[l][c] > 0 then
						target_lane = l
						target_col_idx = c
						target_ticket_idx = #grid[l][c]
						break
					end
				end
				if target_lane then break end
			end
		end

	elseif direction == "down" then
		-- 1. Same cell, next ticket
		if #cell_tickets > 0 and curr_ticket_idx < #cell_tickets then
			target_lane = curr_lane
			target_col_idx = curr_col_idx
			target_ticket_idx = curr_ticket_idx + 1
		else
			-- 2. Search cells below in same column
			for l = curr_lane + 1, N do
				if #grid[l][curr_col_idx] > 0 then
					target_lane = l
					target_col_idx = curr_col_idx
					target_ticket_idx = 1
					break
				end
			end
			-- 3. Search next columns
			if not target_lane then
				for c = curr_col_idx + 1, C do
					for l = 1, N do
						if #grid[l][c] > 0 then
							target_lane = l
							target_col_idx = c
							target_ticket_idx = 1
							break
						end
					end
					if target_lane then break end
				end
			end
			-- 4. Wrap to beginning
			if not target_lane then
				for c = 1, C do
					for l = 1, N do
						if #grid[l][c] > 0 then
							target_lane = l
							target_col_idx = c
							target_ticket_idx = 1
							break
						end
					end
					if target_lane then break end
				end
			end
		end

	elseif direction == "up" then
		-- 1. Same cell, previous ticket
		if #cell_tickets > 0 and curr_ticket_idx > 1 then
			target_lane = curr_lane
			target_col_idx = curr_col_idx
			target_ticket_idx = curr_ticket_idx - 1
		else
			-- 2. Search cells above in same column
			for l = curr_lane - 1, 1, -1 do
				if #grid[l][curr_col_idx] > 0 then
					target_lane = l
					target_col_idx = curr_col_idx
					target_ticket_idx = #grid[l][curr_col_idx]
					break
				end
			end
			-- 3. Search previous columns
			if not target_lane then
				for c = curr_col_idx - 1, 1, -1 do
					for l = N, 1, -1 do
						if #grid[l][c] > 0 then
							target_lane = l
							target_col_idx = c
							target_ticket_idx = #grid[l][c]
							break
						end
					end
					if target_lane then break end
				end
			end
			-- 4. Wrap to end
			if not target_lane then
				for c = C, 1, -1 do
					for l = N, 1, -1 do
						if #grid[l][c] > 0 then
							target_lane = l
							target_col_idx = c
							target_ticket_idx = #grid[l][c]
							break
						end
					end
					if target_lane then break end
				end
			end
		end
	end

	-- Execute cursor jump if target is found
	if target_lane and target_col_idx and target_ticket_idx then
		local target_entry = grid[target_lane][target_col_idx][target_ticket_idx]
		local target_col = target_entry.col
		local target_win = M.board_state.windows[target_col]

		if not target_win or not vim.api.nvim_win_is_valid(target_win) then
			-- Scroll to make target_col visible
			local _, sorted_statuses = M.get_columns()
			local target_status_idx = nil
			for idx, s in ipairs(sorted_statuses) do
				if s.name == target_col then
					target_status_idx = idx
					break
				end
			end
			if target_status_idx and M.board_state.board_win and M.board_state.board_win:valid() then
				local board_w = vim.api.nvim_win_get_width(M.board_state.board_win.win)
				local board_h = vim.api.nvim_win_get_height(M.board_state.board_win.win)
				local visible_count = select(4, M.layout_columns(board_w))

				if target_status_idx < M.board_state.scroll_index then
					M.board_state.scroll_index = target_status_idx
				elseif target_status_idx >= M.board_state.scroll_index + visible_count then
					M.board_state.scroll_index = target_status_idx - visible_count + 1
				end

				M.recreate_column_windows(board_w, board_h, target_col)
				M.render_board()
				target_win = M.board_state.windows[target_col]
			end
		end

		if target_win and vim.api.nvim_win_is_valid(target_win) then
			vim.api.nvim_set_current_win(target_win)
			pcall(vim.api.nvim_win_set_cursor, target_win, { target_entry.line, 2 })
		end
	end
end

-- Helper: Smart navigate lane-by-lane (group-by-group) on the Kanban board
local function smart_navigate_lane(direction)
	local col_name = get_current_column_name()
	if not col_name then return end

	local win = vim.api.nvim_get_current_win()
	local cursor = vim.api.nvim_win_get_cursor(win)
	local curr_line = cursor[1]

	-- Get sorted statuses to define columns order
	local sorted_statuses = {}
	for status_name, rank in pairs(config.STATUS_SORT) do
		table.insert(sorted_statuses, { name = status_name, rank = rank })
	end
	table.sort(sorted_statuses, function(a, b)
		return a.rank < b.rank
	end)

	local cols = {}
	for _, s in ipairs(sorted_statuses) do
		table.insert(cols, s.name)
	end

	local lane_starts = M.board_state.lane_start_lines or {}
	if #lane_starts == 0 then return end

	local sorted_lane_starts = vim.deepcopy(lane_starts)
	table.sort(sorted_lane_starts)

	local g_buf = M.board_state.buffers["GROUPING"]
	if not g_buf or not vim.api.nvim_buf_is_valid(g_buf) then return end
	local total_lines = vim.api.nvim_buf_line_count(g_buf)

	local grid = {}
	local N = #sorted_lane_starts
	local C = #cols

	for l_idx = 1, N do
		grid[l_idx] = {}
		local start_line = sorted_lane_starts[l_idx]
		local end_line = total_lines
		if l_idx < N then
			end_line = sorted_lane_starts[l_idx + 1] - 4
		end

		for c_idx = 1, C do
			local col = cols[c_idx]
			grid[l_idx][c_idx] = {}
			local mappings = M.board_state.line_mappings[col] or {}
			local last_id = nil
			for l = start_line, end_line do
				local todo = mappings[l]
				if todo then
					if todo.id ~= last_id then
						table.insert(grid[l_idx][c_idx], {
							col = col,
							line = l,
							id = todo.id,
							lane = l_idx,
							col_idx = c_idx,
						})
						last_id = todo.id
					end
				end
			end
		end
	end

	-- Determine current lane and column index
	local curr_lane = nil
	for l_idx = 1, N do
		local start_line = sorted_lane_starts[l_idx]
		local end_line = total_lines
		if l_idx < N then
			end_line = sorted_lane_starts[l_idx + 1] - 4
		end
		if curr_line >= start_line and curr_line <= end_line then
			curr_lane = l_idx
			break
		end
	end
	if not curr_lane then
		-- Fallback to closest lane
		local best_diff = 999999
		for l_idx = 1, N do
			local diff = math.abs(sorted_lane_starts[l_idx] - curr_line)
			if diff < best_diff then
				best_diff = diff
				curr_lane = l_idx
			end
		end
	end

	local curr_col_idx = nil
	for c_idx = 1, C do
		if cols[c_idx] == col_name then
			curr_col_idx = c_idx
			break
		end
	end
	if not curr_col_idx then return end

	-- Search for next or previous lane that has cards in ANY column
	local target_lane = nil
	if direction == "next" then
		for offset = 1, N do
			local l = (curr_lane + offset - 1) % N + 1
			if l ~= curr_lane or N == 1 then
				local has_cards = false
				for c = 1, C do
					if #grid[l][c] > 0 then
						has_cards = true
						break
					end
				end
				if has_cards then
					target_lane = l
					break
				end
			end
		end
	else
		for offset = 1, N do
			local l = (curr_lane - offset - 1) % N + 1
			if l < 1 then l = l + N end
			if l ~= curr_lane or N == 1 then
				local has_cards = false
				for c = 1, C do
					if #grid[l][c] > 0 then
						has_cards = true
						break
					end
				end
				if has_cards then
					target_lane = l
					break
				end
			end
		end
	end

	if target_lane then
		local target = nil
		-- Find the first column in status order that has a ticket
		for c = 1, C do
			if #grid[target_lane][c] > 0 then
				target = grid[target_lane][c][1]
				break
			end
		end
		if target then
			local target_win = M.board_state.windows[target.col]
			if not target_win or not vim.api.nvim_win_is_valid(target_win) then
				-- Scroll to make target_col visible
				local _, sorted_statuses = M.get_columns()
				local target_status_idx = nil
				for idx, s in ipairs(sorted_statuses) do
					if s.name == target.col then
						target_status_idx = idx
						break
					end
				end
				if target_status_idx and M.board_state.board_win and M.board_state.board_win:valid() then
					local board_w = vim.api.nvim_win_get_width(M.board_state.board_win.win)
					local board_h = vim.api.nvim_win_get_height(M.board_state.board_win.win)
					local visible_count = select(4, M.layout_columns(board_w))

					if target_status_idx < M.board_state.scroll_index then
						M.board_state.scroll_index = target_status_idx
					elseif target_status_idx >= M.board_state.scroll_index + visible_count then
						M.board_state.scroll_index = target_status_idx - visible_count + 1
					end

					M.recreate_column_windows(board_w, board_h, target.col)
					M.render_board()
					target_win = M.board_state.windows[target.col]
				end
			end

			if target_win and vim.api.nvim_win_is_valid(target_win) then
				vim.api.nvim_set_current_win(target_win)
				pcall(vim.api.nvim_win_set_cursor, target_win, { target.line, 2 })
			end
		end
	end
end

-- Helper: Open the parent ticket details modal from the board
local function open_parent_ticket()
	local todo_id, col_name = save_cursor_position()
	if not todo_id then
		return
	end

	local item = store.get_todo_item_by_id(todo_id)
	if not item then
		return
	end

	local parent_id = item.parent_id
	if not parent_id or parent_id == "" then
		utils.notify_todo("This todo has no parent", vim.log.levels.WARN)
		return
	end

	local parent_item = store.get_todo_item_by_id(parent_id)
	if not parent_item then
		utils.notify_todo("Parent todo not found", vim.log.levels.WARN)
		return
	end

	ui.open_todo_detail(nil, parent_item, {
		start_zone = "log",
		start_insert = false,
		on_close = function()
			M.render_board()
		end
	})
end

-- Highlight all lines of the card under cursor (called on CursorMoved)
local function update_card_highlight()
	if M.board_state.rendering then return end
	local col_name = get_current_column_name()
	if not col_name then return end

	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_get_current_buf()
	local cursor = vim.api.nvim_win_get_cursor(win)
	local curr_line = cursor[1]
	local mappings = M.board_state.line_mappings[col_name] or {}
	local ns = M.board_state.hl_ns

	-- Clear previous selection highlights across all status buffers
	for _, b in pairs(M.board_state.buffers) do
		if b and vim.api.nvim_buf_is_valid(b) then
			vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
		end
	end

	local todo = mappings[curr_line]
	if not todo then return end

	-- Find the start of this card
	local card_start = curr_line
	while card_start > 1 and mappings[card_start - 1] and mappings[card_start - 1].id == todo.id do
		card_start = card_start - 1
	end

	-- Find the end of this card
	local card_end = curr_line
	local total_lines = vim.api.nvim_buf_line_count(buf)
	while card_end < total_lines and mappings[card_end + 1] and mappings[card_end + 1].id == todo.id do
		card_end = card_end + 1
	end

	-- Highlight top border line
	vim.api.nvim_buf_add_highlight(buf, ns, "TodoBoardActiveBorder", card_start - 1, 0, -1)

	-- Highlight body borders (left and right │)
	for l = card_start + 1, card_end - 1 do
		local line_content = vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1] or ""
		local line_len = #line_content
		if line_len >= 6 then
			-- Left border character │
			vim.api.nvim_buf_add_highlight(buf, ns, "TodoBoardActiveBorder", l - 1, 0, 3)
			-- Right border character │
			vim.api.nvim_buf_add_highlight(buf, ns, "TodoBoardActiveBorder", l - 1, line_len - 3, line_len)
		end
	end

	-- Highlight bottom border line
	vim.api.nvim_buf_add_highlight(buf, ns, "TodoBoardActiveBorder", card_end - 1, 0, -1)
end

-- Refresh and render all cards and lanes
function M.render_board()
	if not M.board_state.board_win or not M.board_state.board_win:valid() then
		return
	end
	local old_ei = vim.o.eventignore
	vim.o.eventignore = "all"
	M.board_state.rendering = true

	-- Disable scrollbind before modifications to avoid scroll offset drifts
	for _, win in pairs(M.board_state.windows) do
		if win and vim.api.nvim_win_is_valid(win) then
			vim.wo[win].scrollbind = false
		end
	end

	-- Reset lane navigation tracker
	M.board_state.lane_start_lines = {}

	local store_obj = store.load_store()
	local todos = store_obj.todos or {}
	local picker_mod = require("todo-picker.picker")

	local title_by_id = {}
	for _, t in ipairs(todos) do
		if t.id then
			title_by_id[t.id] = t.title
		end
	end
	M.board_state.title_by_id = title_by_id

	-- Filter active todos based on retention (same rules as list)
	local active_todos = {}
	for _, todo in ipairs(todos) do
		if todo.status == config.STATUS_DONE then
			local dummy_item = { todo_completed_date = todo.completed or "" }
			if picker_mod.should_keep_done_item(dummy_item, true) then
				table.insert(active_todos, todo)
			end
		else
			table.insert(active_todos, todo)
		end
	end

	-- Get group lanes
	local groups
	if M.board_state.group_by == "parent" then
		groups = get_parent_groups(active_todos)
	elseif M.board_state.group_by == "tag" then
		groups = get_tag_groups(active_todos)
	else
		groups = get_flat_groups(active_todos)
	end
	M.board_state.groups = groups

	-- Get columns
	local sorted_statuses = {}
	for status_name, rank in pairs(config.STATUS_SORT) do
		table.insert(sorted_statuses, { name = status_name, rank = rank })
	end
	table.sort(sorted_statuses, function(a, b)
		return a.rank < b.rank
	end)

	local columns = { "GROUPING" }
	for _, s in ipairs(sorted_statuses) do
		table.insert(columns, s.name)
	end

	local render_data = {}
	for _, col in ipairs(columns) do
		render_data[col] = {
			lines = {},
			hls = {},
		}
		M.board_state.line_mappings[col] = {}
	end

	-- Process lanes
	for _, g in ipairs(groups) do
		local total_count = 0
		local done_count = 0
		for _, t in ipairs(g.todos) do
			if not g.is_virtual or t.id ~= g.id then
				total_count = total_count + 1
				if t.status == config.STATUS_DONE then
					done_count = done_count + 1
				end
			end
		end

		local tasks_by_status = {}
		for _, s in ipairs(sorted_statuses) do
			tasks_by_status[s.name] = {}
		end
		for _, t in ipairs(g.todos) do
			if tasks_by_status[t.status] then
				table.insert(tasks_by_status[t.status], t)
			end
		end

		for _, s in ipairs(sorted_statuses) do
			table.sort(tasks_by_status[s.name], function(a, b)
				local rank_a = config.PRIORITY_SORT[a.priority] or 9
				local rank_b = config.PRIORITY_SORT[b.priority] or 9
				if rank_a ~= rank_b then
					return rank_a < rank_b
				end
				local date_a = utils.parse_date_to_sortkey(a.created)
				local date_b = utils.parse_date_to_sortkey(b.created)
				return date_a < date_b
			end)
		end

		-- Determine the max height for this lane
		-- Calculate wrapped title lines for grouping column
		local group_win = M.board_state.windows["GROUPING"]
		local group_width = (group_win and vim.api.nvim_win_is_valid(group_win))
				and vim.api.nvim_win_get_width(group_win)
			or 20
		local group_inner_w = group_width - 4
		local wrapped_group_title = wrap_text(g.title:upper(), group_inner_w, group_inner_w)
		local group_box_height = #wrapped_group_title + 3 -- top (1) + wrapped title (#wrapped) + progress (1) + bottom (1)

		local max_cards_height = 0
		for _, s in ipairs(sorted_statuses) do
			local s_tasks = tasks_by_status[s.name]
			local h = 0
			if #s_tasks > 0 then
				local s_win = M.board_state.windows[s.name]
				local s_width = (s_win and vim.api.nvim_win_is_valid(s_win))
						and vim.api.nvim_win_get_width(s_win)
					or 30
				local inner_w = s_width - 4
				local total_title_lines = 0
				local sub_text_lines = 0
				for _, todo in ipairs(s_tasks) do
					local priority_badge = config.PRIORITY_BADGE[todo.priority] or " "
					local badge_w = vim.fn.strdisplaywidth(priority_badge .. " ")
					local wrapped_title_lines = wrap_text(todo.title, inner_w - badge_w, inner_w - badge_w)
					total_title_lines = total_title_lines + #wrapped_title_lines

					local sub_text = nil
					local group_by = M.board_state.group_by
					if group_by == "tag" then
						if todo.parent_id and todo.parent_id ~= "" then
							local title_by_id = M.board_state.title_by_id or {}
							local parent_title = title_by_id[todo.parent_id] or todo.parent_id
							sub_text = "[" .. parent_title .. "]"
						end
					elseif group_by == "parent" then
						if todo.labels and #todo.labels > 0 then
							local label_tokens = {}
							for _, label in ipairs(todo.labels) do
								table.insert(label_tokens, "#" .. tostring(label))
							end
							sub_text = table.concat(label_tokens, " ")
						end
					end
					if sub_text and sub_text ~= "" then
						sub_text_lines = sub_text_lines + 1
					end
				end
				h = total_title_lines + sub_text_lines + 3 * #s_tasks - 1
			end
			if h > max_cards_height then
				max_cards_height = h
			end
		end

		local lane_height = math.max(group_box_height, max_cards_height)

		-- Leftmost grouping column header rendered as a continuous box spanning the lane height
		local col_data = render_data["GROUPING"]
		local width = group_width

		local text_hl = "SnacksPickerKeymapLhs"
		local border_hl = text_hl

		-- Find parent todo for mappings if applicable
		local parent_todo = nil
		if not g.is_virtual then
			for _, t in ipairs(g.todos) do
				if t.id == g.id then
					parent_todo = t
					break
				end
			end
		end
		local mapping_todo = parent_todo or { id = g.id, title = g.title, is_group = true }

		-- Record lane start line for navigation (same across all columns)
		local lane_start_line = #col_data.lines + 1
		table.insert(M.board_state.lane_start_lines, lane_start_line)

		-- Top border
		table.insert(col_data.lines, "╭" .. string.rep("─", width - 2) .. "╮")
		table.insert(col_data.hls, { #col_data.lines - 1, 0, -1, "Comment" })
		M.board_state.line_mappings["GROUPING"][#col_data.lines] = mapping_todo

		-- Title
		for _, tl in ipairs(wrapped_group_title) do
			local line = "│ " .. tl .. string.rep(" ", math.max(0, group_inner_w - vim.fn.strdisplaywidth(tl))) .. " │"
			table.insert(col_data.lines, line)
			local line_len = #line
			table.insert(col_data.hls, { #col_data.lines - 1, 0, 3, border_hl })
			table.insert(col_data.hls, { #col_data.lines - 1, 3, line_len - 3, "Normal" })
			table.insert(col_data.hls, { #col_data.lines - 1, line_len - 3, line_len, "Comment" })
			M.board_state.line_mappings["GROUPING"][#col_data.lines] = mapping_todo
		end

		-- Progress (Modern Unicode progress bar block)
		local filled_w = 0
		local bar_w = group_inner_w - 7 -- leave 7 cells for numbers like " 2/3"
		if bar_w < 5 then
			bar_w = group_inner_w
		end
		if total_count > 0 then
			filled_w = math.floor((done_count / total_count) * bar_w)
		end
		local bar_filled = string.rep("█", filled_w)
		local bar_empty = string.rep("░", bar_w - filled_w)
		local progress_text = ""
		if bar_w == group_inner_w then
			progress_text = bar_filled .. bar_empty
		else
			progress_text = string.format("%s%s %d/%d", bar_filled, bar_empty, done_count, total_count)
		end

		local p_text = "│ " .. progress_text .. string.rep(" ", math.max(0, group_inner_w - vim.fn.strdisplaywidth(progress_text))) .. " │"
		table.insert(col_data.lines, p_text)
		local p_len = #p_text
		table.insert(col_data.hls, { #col_data.lines - 1, 0, 3, border_hl })
		table.insert(col_data.hls, { #col_data.lines - 1, p_len - 3, p_len, "Comment" })

		-- Highlight filled portion in status color and empty in Comment
		local p_start = #("│ ")
		local p_filled_end = p_start + #bar_filled
		table.insert(col_data.hls, { #col_data.lines - 1, p_start, p_filled_end, "TodoStatusDone" })
		table.insert(col_data.hls, { #col_data.lines - 1, p_filled_end, p_len - 3, "Comment" })
		M.board_state.line_mappings["GROUPING"][#col_data.lines] = mapping_todo

		-- Bottom border
		table.insert(col_data.lines, "╰" .. string.rep("─", width - 2) .. "╯")
		table.insert(col_data.hls, { #col_data.lines - 1, 0, -1, "Comment" })
		M.board_state.line_mappings["GROUPING"][#col_data.lines] = mapping_todo

		-- Pad remaining grouping column height with empty lines
		local group_box_fixed = #wrapped_group_title + 3
		local group_padding = math.max(0, lane_height - group_box_fixed)
		for pad = 1, group_padding do
			table.insert(col_data.lines, "")
		end

		-- Status columns
		for _, s in ipairs(sorted_statuses) do
			local s_tasks = tasks_by_status[s.name]
			local s_col_data = render_data[s.name]
			local s_win = M.board_state.windows[s.name]
			local s_width = (s_win and vim.api.nvim_win_is_valid(s_win))
					and vim.api.nvim_win_get_width(s_win)
				or 30

			local s_lines, s_hls, s_mappings = render_column_lane(s_tasks, s_width, lane_height)

			-- Write the rendered tickets into the column data
			local start_abs_idx = #s_col_data.lines
			for _, line in ipairs(s_lines) do
				table.insert(s_col_data.lines, line)
			end
			for _, hl in ipairs(s_hls) do
				table.insert(s_col_data.hls, { start_abs_idx + hl[1], hl[2], hl[3], hl[4] })
			end
			for rel_idx, todo in pairs(s_mappings) do
				M.board_state.line_mappings[s.name][start_abs_idx + rel_idx] = todo
			end
		end

		-- Draw row separator and gap in all columns for larger gap between groups
		for _, col in ipairs(columns) do
			local c_data = render_data[col]
			local col_win = M.board_state.windows[col]
			local c_width = (col_win and vim.api.nvim_win_is_valid(col_win))
					and vim.api.nvim_win_get_width(col_win)
				or 30
			table.insert(c_data.lines, "") -- 1-line empty gap before separator
			table.insert(c_data.lines, string.rep("─", c_width)) -- separator line
			local abs_line = #c_data.lines
			table.insert(c_data.hls, { abs_line - 1, 0, -1, "Comment" })
			table.insert(c_data.lines, "") -- 1-line empty gap after separator
		end
	end

	-- Write buffer contents and apply highlights
	local ns = vim.api.nvim_create_namespace("todo_kanban_highlights")
	for _, col in ipairs(columns) do
		local buf = M.board_state.buffers[col]
		local c_data = render_data[col]
		if buf and vim.api.nvim_buf_is_valid(buf) then
			vim.bo[buf].modifiable = true
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, c_data.lines)
			vim.bo[buf].modifiable = false

			vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
			for _, hl in ipairs(c_data.hls) do
				vim.api.nvim_buf_add_highlight(buf, ns, hl[4], hl[1], hl[2], hl[3])
			end
		end
	end

	-- Update winbar task counts
	local status_icons = {
		[config.STATUS_TODO] = "",
		[config.STATUS_BLOCKED] = "",
		[config.STATUS_DOING] = "",
		[config.STATUS_PEER_REVIEW] = "",
		[config.STATUS_DONE] = "",
	}

	for _, s in ipairs(sorted_statuses) do
		local s_name = s.name
		local win = M.board_state.windows[s_name]
		if win and vim.api.nvim_win_is_valid(win) then
			local count = 0
			for _, t in ipairs(active_todos) do
				if t.status == s_name then
					count = count + 1
				end
			end
			local display_name = config.STATUS_LABEL[s_name] or s_name
			local hl_group = config.STATUS_COLOR[config.STATUS_SORT[s_name] or 0] or "Title"
			local icon = status_icons[s_name] or ""
			vim.wo[win].winbar = "%#" .. hl_group .. "#  " .. icon .. " " .. display_name:upper() .. " %#Comment#(" .. count .. ")  "
		end
	end

	-- Update grouping column winbar title based on group_by mode
	local group_win = M.board_state.windows["GROUPING"]
	if group_win and vim.api.nvim_win_is_valid(group_win) then
		local group_title = "ALL"
		if M.board_state.group_by == "parent" then
			group_title = "PARENT"
		elseif M.board_state.group_by == "tag" then
			group_title = "TAG"
		end
		vim.wo[group_win].winbar = "%#SnacksPickerKeymapLhs#  󰉋 " .. group_title .. "  "
	end

	-- Align all windows scroll positions to the active window
	local active_win = vim.api.nvim_get_current_win()
	local ok_view, active_view = pcall(vim.api.nvim_win_call, active_win, vim.fn.winsaveview)
	if ok_view and active_view then
		for _, win in pairs(M.board_state.windows) do
			if win and vim.api.nvim_win_is_valid(win) and win ~= active_win then
				vim.api.nvim_win_call(win, function()
					local view = vim.fn.winsaveview()
					view.topline = active_view.topline
					vim.fn.winrestview(view)
				end)
			end
		end
	end

	-- Re-enable scrollbind on all windows
	for _, win in pairs(M.board_state.windows) do
		if win and vim.api.nvim_win_is_valid(win) then
			vim.wo[win].scrollbind = true
		end
	end
	M.board_state.rendering = false
	vim.o.eventignore = old_ei
end

-- Keymap Action: Move ticket left/right (status change)
local function move_ticket_status(direction)
	local todo_id, col_name = save_cursor_position()
	if not todo_id or not col_name then
		utils.notify_todo("No todo under cursor to move", vim.log.levels.WARN)
		return
	end

	local sorted_statuses = {}
	for status_name, rank in pairs(config.STATUS_SORT) do
		table.insert(sorted_statuses, { name = status_name, rank = rank })
	end
	table.sort(sorted_statuses, function(a, b)
		return a.rank < b.rank
	end)

	local current_idx = nil
	for i, s in ipairs(sorted_statuses) do
		if s.name == col_name then
			current_idx = i
			break
		end
	end

	if not current_idx then
		return
	end

	local target_idx = current_idx + (direction == "right" and 1 or -1)
	if target_idx < 1 or target_idx > #sorted_statuses then
		return
	end

	local next_status = sorted_statuses[target_idx].name

	local ok, updated_item = store.update_todo_by_id(todo_id, function(t)
		t.status = next_status
		if next_status == config.STATUS_DONE then
			t.completed = utils.today()
		else
			t.completed = nil
		end
		return t
	end)

	if ok then
		M.render_board()
		restore_cursor_position(todo_id, next_status)
	end
end

-- Keymap Action: Change ticket priority
local function change_ticket_priority(direction)
	local todo_id, col_name = save_cursor_position()
	if not todo_id or not col_name then
		utils.notify_todo("No todo under cursor to change priority", vim.log.levels.WARN)
		return
	end

	local priority_order = { config.PRIORITY_LOW, config.PRIORITY_MEDIUM, config.PRIORITY_HIGH }
	local current_priority = nil

	local store_obj = store.load_store()
	local bucket = store.find_todo_bucket(store_obj, todo_id)
	if not bucket then
		return
	end
	local todo = bucket.todo

	for i, p in ipairs(priority_order) do
		if p == todo.priority then
			current_priority = i
			break
		end
	end

	if not current_priority then
		current_priority = 1
	end

	local target_priority_idx = current_priority + (direction == "up" and 1 or -1)
	if target_priority_idx < 1 or target_priority_idx > #priority_order then
		return
	end

	local next_priority = priority_order[target_priority_idx]

	local ok = store.update_todo_by_id(todo_id, function(t)
		t.priority = next_priority
		return t
	end)

	if ok then
		M.render_board()
		restore_cursor_position(todo_id, col_name)
	end
end

-- Keymap Action: Cycle/Toggle ticket status
local function toggle_ticket_status()
	local todo_id, col_name = save_cursor_position()
	if not todo_id or not col_name then
		utils.notify_todo("No todo under cursor to change status", vim.log.levels.WARN)
		return
	end

	local sorted_statuses = {}
	for status_name, rank in pairs(config.STATUS_SORT) do
		table.insert(sorted_statuses, { name = status_name, rank = rank })
	end
	table.sort(sorted_statuses, function(a, b)
		return a.rank < b.rank
	end)

	local store_obj = store.load_store()
	local bucket = store.find_todo_bucket(store_obj, todo_id)
	if not bucket then
		return
	end
	local todo = bucket.todo

	local current_idx = nil
	for i, s in ipairs(sorted_statuses) do
		if s.name == todo.status then
			current_idx = i
			break
		end
	end

	if not current_idx then
		current_idx = 1
	end
	local next_idx = (current_idx % #sorted_statuses) + 1
	local next_status = sorted_statuses[next_idx].name

	local ok = store.update_todo_by_id(todo_id, function(t)
		t.status = next_status
		if next_status == config.STATUS_DONE then
			t.completed = utils.today()
		else
			t.completed = nil
		end
		return t
	end)

	if ok then
		M.render_board()
		restore_cursor_position(todo_id, next_status)
	end
end

-- Keymap Action: Cycle/Toggle ticket priority
local function toggle_ticket_priority()
	local todo_id, col_name = save_cursor_position()
	if not todo_id or not col_name then
		utils.notify_todo("No todo under cursor to change priority", vim.log.levels.WARN)
		return
	end

	local priority_order = { config.PRIORITY_LOW, config.PRIORITY_MEDIUM, config.PRIORITY_HIGH }
	local current_priority = nil

	local store_obj = store.load_store()
	local bucket = store.find_todo_bucket(store_obj, todo_id)
	if not bucket then
		return
	end
	local todo = bucket.todo

	for i, p in ipairs(priority_order) do
		if p == todo.priority then
			current_priority = i
			break
		end
	end

	if not current_priority then
		current_priority = 1
	end
	local next_idx = (current_priority % #priority_order) + 1
	local next_priority = priority_order[next_idx]

	local ok = store.update_todo_by_id(todo_id, function(t)
		t.priority = next_priority
		return t
	end)

	if ok then
		M.render_board()
		restore_cursor_position(todo_id, col_name)
	end
end

-- Keymap Action: Edit ticket details
local function edit_ticket()
	local todo_id, col_name = save_cursor_position()
	if not todo_id then
		utils.notify_todo("No todo under cursor to edit", vim.log.levels.WARN)
		return
	end

	local item = store.get_todo_item_by_id(todo_id)
	if not item then
		return
	end

	ui.open_todo_detail(nil, item, {
		start_zone = "log",
		start_insert = false,
	})
end

-- Keymap Action: Context-aware ticket creation
local function add_ticket()
	local todo_id, col_name = save_cursor_position()
	local status = (col_name and col_name ~= "GROUPING") and col_name or config.STATUS_TODO
	local group_id = "independent"

	local win = vim.api.nvim_get_current_win()
	local cursor = vim.api.nvim_win_get_cursor(win)
	local curr_line = cursor[1]

	local lane_starts = M.board_state.lane_start_lines or {}
	local groups = M.board_state.groups or {}
	local l_idx = nil
	for i, start_line in ipairs(lane_starts) do
		if curr_line >= start_line then
			l_idx = i
		else
			break
		end
	end

	if l_idx and groups[l_idx] then
		group_id = groups[l_idx].id
	end

	local draft = {
		title = "",
		status = status,
		parent_id = nil,
		labels = {},
	}

	if M.board_state.group_by == "parent" and group_id ~= "independent" then
		draft.parent_id = group_id
	elseif M.board_state.group_by == "tag" and group_id ~= "untagged" and group_id:match("^tag:") then
		local tag_name = group_id:sub(5)
		draft.labels = { tag_name }
	end

	ui.open_new_todo_draft(nil, nil, draft)
end

-- Keymap Action: Delete ticket under cursor
local function delete_ticket()
	local todo_id, col_name = save_cursor_position()
	if not todo_id then
		utils.notify_todo("No todo under cursor to delete", vim.log.levels.WARN)
		return
	end

	local item = store.get_todo_item_by_id(todo_id)
	if not item then
		return
	end

	if not ui.confirm_delete_todos({ item }) then
		return
	end

	if store.delete_todo_by_id(todo_id) then
		M.render_board()
		restore_cursor_position(nil, col_name)
	end
end

-- Keymap Action: Cycle grouping mode
local function toggle_grouping()
	local todo_id, col_name = save_cursor_position()
	local order = { "parent", "tag", "none" }
	local next_idx = 1
	for i, mode in ipairs(order) do
		if mode == M.board_state.group_by then
			next_idx = (i % #order) + 1
			break
		end
	end
	M.board_state.group_by = order[next_idx]

	-- Temporarily ignore all autocommands during layout recreation and render
	local old_eventignore = vim.o.eventignore
	vim.o.eventignore = "all"

	if M.board_state.board_win and M.board_state.board_win:valid() then
		local board_w = vim.api.nvim_win_get_width(M.board_state.board_win.win)
		local board_h = vim.api.nvim_win_get_height(M.board_state.board_win.win)
		local current_focus = get_current_column_name() or col_name or "TODO"
		M.recreate_column_windows(board_w, board_h, current_focus)
	end

	M.render_board()

	vim.o.eventignore = old_eventignore

	focus_first_ticket_on_board()
end

-- Keymap Action: Toggle help window for Kanban board
local function toggle_kanban_help()
	if M.board_state.help_win and vim.api.nvim_win_is_valid(M.board_state.help_win) then
		pcall(vim.api.nvim_win_close, M.board_state.help_win, true)
		M.board_state.help_win = nil
		return
	end

	local help_lines = {
		"  Kanban Board Keys",
		"",
		"  h / l    Smart navigate left/right",
		"  j / k    Smart navigate down/up",
		"  Tab/S-Tab Cycle through tickets",
		"  s        Cycle ticket status",
		"  p        Cycle ticket priority",
		"  Enter/e  Edit ticket details",
		"  t        Add new ticket in current lane/status",
		"  D        Delete ticket with confirmation",
		"  g        Cycle grouping (parent -> tag -> none)",
		"  ?        Toggle this help window",
		"  q / Esc  Close Kanban board",
	}

	local max_len = 0
	for _, line in ipairs(help_lines) do
		max_len = math.max(max_len, vim.fn.strdisplaywidth(line))
	end

	local h = #help_lines
	local w = math.max(48, math.min(max_len + 4, math.floor(vim.o.columns * 0.6)))

	local hbuf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(hbuf, 0, -1, false, help_lines)
	vim.bo[hbuf].modifiable = false
	vim.bo[hbuf].bufhidden = "wipe"
	vim.bo[hbuf].buftype = "nofile"

	local UI = config.options.ui
	local help_win = vim.api.nvim_open_win(hbuf, true, {
		relative = "editor",
		width = w,
		height = h,
		row = math.floor((vim.o.lines - h) / 2),
		col = math.floor((vim.o.columns - w) / 2),
		style = "minimal",
		border = UI.panel.border,
		zindex = 210,
	})

	M.board_state.help_win = help_win
	vim.wo[help_win].winhighlight = "Normal:Normal,FloatBorder:TodoTransparentBorder,FloatTitle:SnacksPickerKeymapLhs"

	local function close_help_window()
		if M.board_state.help_win and vim.api.nvim_win_is_valid(M.board_state.help_win) then
			pcall(vim.api.nvim_win_close, M.board_state.help_win, true)
			M.board_state.help_win = nil
		end
	end

	vim.keymap.set("n", "q", close_help_window, { buffer = hbuf, nowait = true, silent = true })
	vim.keymap.set("n", "<Esc>", close_help_window, { buffer = hbuf, nowait = true, silent = true })
	vim.keymap.set("n", "?", close_help_window, { buffer = hbuf, nowait = true, silent = true })
end

-- Setup buffer mappings for Kanban board
local function setup_buffer_keymaps(buf)
	local function map(keys, fn, desc)
		for _, key in ipairs(keys) do
			vim.keymap.set("n", key, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
		end
	end

	map({ "h", "<Left>" }, function()
		smart_navigate_book("left")
	end, "Focus left card")
	map({ "l", "<Right>" }, function()
		smart_navigate_book("right")
	end, "Focus right card")

	map({ "j" }, function()
		smart_navigate_book("down")
	end, "Focus down card")
	map({ "k" }, function()
		smart_navigate_book("up")
	end, "Focus up card")

	map({ "s" }, toggle_ticket_status, "Cycle ticket status")
	map({ "p" }, toggle_ticket_priority, "Cycle ticket priority")

	map({ "<Tab>" }, function()
		smart_navigate_lane("next")
	end, "Next lane")
	map({ "<S-Tab>" }, function()
		smart_navigate_lane("prev")
	end, "Previous lane")

	map({ "P" }, open_parent_ticket, "Open parent ticket")

	map({ "<CR>", "e" }, edit_ticket, "Edit ticket details")
	map({ "t" }, add_ticket, "Add new ticket")
	map({ "D" }, delete_ticket, "Delete ticket")
	map({ "g" }, toggle_grouping, "Cycle grouping mode")
	map({ "?" }, toggle_kanban_help, "Toggle help window")
end

function M.get_columns()
	local sorted_statuses = {}
	for status_name, rank in pairs(config.STATUS_SORT) do
		table.insert(sorted_statuses, { name = status_name, rank = rank })
	end
	table.sort(sorted_statuses, function(a, b)
		return a.rank < b.rank
	end)

	local columns = { "GROUPING" }
	for _, s in ipairs(sorted_statuses) do
		table.insert(columns, s.name)
	end
	return columns, sorted_statuses
end

function M.layout_columns(board_w)
	local columns, sorted_statuses = M.get_columns()
	local num_status_cols = #sorted_statuses
	local available_w = board_w - 1 -- leave 1 cell margin on the right for border visibility

	local min_col_width = 15
	local visible_status_count = num_status_cols

	local status_cell_w, grouping_w
	while visible_status_count > 0 do
		-- Status cell width = status_w + 1 (for left border)
		-- grouping_w = math.floor(0.7 * status_cell_w)
		-- grouping_w + visible_status_count * status_cell_w = available_w
		status_cell_w = math.floor(available_w / (0.7 + visible_status_count))
		grouping_w = math.floor(0.7 * status_cell_w)
		if status_cell_w >= min_col_width + 1 or visible_status_count == 1 then
			break
		end
		visible_status_count = visible_status_count - 1
	end

	local scroll_idx = M.board_state.scroll_index or 1
	if scroll_idx < 1 then
		scroll_idx = 1
	elseif scroll_idx > num_status_cols - visible_status_count + 1 then
		scroll_idx = num_status_cols - visible_status_count + 1
	end
	M.board_state.scroll_index = scroll_idx

	local remaining_w = available_w - grouping_w
	local base_cell_w = math.floor(remaining_w / visible_status_count)
	local remainder = remaining_w % visible_status_count

	local col_widths = {}
	col_widths["GROUPING"] = grouping_w

	for i = 1, visible_status_count do
		local status_name = sorted_statuses[scroll_idx + i - 1].name
		local cell_w = base_cell_w
		if i <= remainder then
			cell_w = cell_w + 1
		end
		col_widths[status_name] = cell_w - 1
	end

	local col_positions = {}
	local current_col = 0
	col_positions["GROUPING"] = current_col
	current_col = current_col + grouping_w

	for i = 1, visible_status_count do
		local status_name = sorted_statuses[scroll_idx + i - 1].name
		col_positions[status_name] = current_col + 1
		current_col = current_col + col_widths[status_name] + 1
	end

	return col_widths, col_positions, scroll_idx, visible_status_count
end

function M.recreate_column_windows(board_w, board_h, focus_col_name)
	local old_ei = vim.o.eventignore
	vim.o.eventignore = "all"
	local columns, sorted_statuses = M.get_columns()
	local col_widths, col_positions, scroll_idx, visible_count = M.layout_columns(board_w)

	M.board_state.recreating = true
	if M.board_state.windows then
		for _, win_id in pairs(M.board_state.windows) do
			if win_id and vim.api.nvim_win_is_valid(win_id) then
				pcall(vim.api.nvim_win_close, win_id, true)
			end
		end
	end
	M.board_state.recreating = false

	M.board_state.windows = {}
	M.board_state.buffers = {}

	local visible_cols = { "GROUPING" }
	for i = 1, visible_count do
		table.insert(visible_cols, sorted_statuses[scroll_idx + i - 1].name)
	end

	for _, col_name in ipairs(visible_cols) do
		local border_opt
		if col_name == "GROUPING" then
			border_opt = "none"
		else
			border_opt = { "", "", "", "", "", "", "", { "│", "TodoTransparentBorder" } }
		end

		local win = Snacks.win({
			relative = "win",
			win = M.board_state.board_win.win,
			width = col_widths[col_name],
			height = board_h,
			row = 0,
			col = col_positions[col_name],
			border = border_opt,
			enter = (col_name == focus_col_name),
			focusable = (col_name ~= "GROUPING"),
			keys = { q = false },
			wo = {
				number = false,
				relativenumber = false,
				signcolumn = "no",
				statuscolumn = "",
				wrap = false,
				cursorline = false,
				scrollbind = true,
				winfixwidth = true,
				winhighlight = "Normal:Normal,FloatBorder:TodoTransparentBorder",
			},
			bo = {
				buftype = "nofile",
				bufhidden = "wipe",
				swapfile = false,
				modifiable = false,
			},
			on_close = function()
				if M.board_state.recreating then
					return
				end
				vim.schedule(function()
					if M.board_state.board_win and M.board_state.board_win:valid() then
						M.board_state.board_win:close()
					end
				end)
			end,
		})

		M.board_state.windows[col_name] = win.win
		M.board_state.buffers[col_name] = win.buf
		M.board_state.line_mappings[col_name] = {}

		setup_buffer_keymaps(win.buf)

		vim.api.nvim_create_autocmd("CursorMoved", {
			buffer = win.buf,
			callback = update_card_highlight,
		})
	end
	vim.o.eventignore = old_ei

	for _, buf in pairs(M.board_state.buffers) do
		vim.keymap.set("n", "q", function()
			if M.board_state.board_win and M.board_state.board_win:valid() then
				M.board_state.board_win:close()
			end
		end, { buffer = buf, silent = true, nowait = true })
		vim.keymap.set("n", "<Esc>", function()
			if M.board_state.board_win and M.board_state.board_win:valid() then
				M.board_state.board_win:close()
			end
		end, { buffer = buf, silent = true, nowait = true })
	end
end

function M.open_kanban(opts)
	opts = opts or {}

	if M.board_state.board_win and M.board_state.board_win:valid() then
		local grouping_win = M.board_state.windows["GROUPING"]
		if grouping_win and vim.api.nvim_win_is_valid(grouping_win) then
			vim.api.nvim_set_current_win(grouping_win)
		end
		return
	end

	-- Save original window and buffer behind the float
	local prev_win = vim.api.nvim_get_current_win()
	local prev_buf = vim.api.nvim_win_get_buf(prev_win)
	M.board_state.prev_win = prev_win
	M.board_state.prev_buf = prev_buf

	-- Save original window options of the background window
	M.board_state.prev_wo = {
		number = vim.wo[prev_win].number,
		relativenumber = vim.wo[prev_win].relativenumber,
		signcolumn = vim.wo[prev_win].signcolumn,
		foldcolumn = vim.wo[prev_win].foldcolumn,
	}

	-- Temporarily hide background window options to make it clean
	vim.wo[prev_win].number = false
	vim.wo[prev_win].relativenumber = false
	vim.wo[prev_win].signcolumn = "no"
	vim.wo[prev_win].foldcolumn = "0"

	-- Set the background window buffer to a temporary empty scratch buffer
	local scratch_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(scratch_buf, "bufhidden", "wipe")
	vim.api.nvim_win_set_buf(prev_win, scratch_buf)

	local total_w = vim.o.columns
	local total_h = vim.o.lines
	local statusline_h = (vim.o.laststatus > 0) and 1 or 0
	local tabline_h = (vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1)) and 1 or 0
	local cmd_h = vim.o.cmdheight
	local usable_h = total_h - cmd_h - statusline_h - tabline_h

	local board_w = math.max(40, math.min(total_w - 4, math.floor(total_w * 0.96)))
	if (total_w - board_w) % 2 ~= 0 then
		board_w = board_w - 1
	end

	local board_h = math.max(15, math.min(usable_h - 4, math.floor(usable_h * 0.88)))
	if (usable_h - board_h) % 2 ~= 0 then
		board_h = board_h - 1
	end

	local row = (usable_h - board_h) / 2
	local col = (total_w - board_w) / 2

	M.board_state.board_win = Snacks.win({
		relative = "editor",
		width = board_w,
		height = board_h,
		row = row,
		col = col,
		border = "rounded",
		backdrop = 60,
		enter = false,
		focusable = false,
		wo = {
			winhighlight = "Normal:Normal,FloatBorder:TodoTransparentBorder,FloatTitle:SnacksPickerKeymapLhs",
		},
		on_close = function()
			pcall(vim.api.nvim_del_augroup_by_name, "todo_kanban_resize")

			-- Restore background window options and buffer
			if M.board_state.prev_win and vim.api.nvim_win_is_valid(M.board_state.prev_win) then
				if M.board_state.prev_buf and vim.api.nvim_buf_is_valid(M.board_state.prev_buf) then
					pcall(vim.api.nvim_win_set_buf, M.board_state.prev_win, M.board_state.prev_buf)
				end
				if M.board_state.prev_wo then
					for opt, val in pairs(M.board_state.prev_wo) do
						pcall(function()
							vim.wo[M.board_state.prev_win][opt] = val
						end)
					end
				end
			end

			if M.board_state.help_win and vim.api.nvim_win_is_valid(M.board_state.help_win) then
				pcall(vim.api.nvim_win_close, M.board_state.help_win, true)
				M.board_state.help_win = nil
			end
			if M.board_state.windows then
				for _, win_id in pairs(M.board_state.windows) do
					if win_id and vim.api.nvim_win_is_valid(win_id) then
						pcall(vim.api.nvim_win_close, win_id, true)
					end
				end
			end
			M.board_state.board_win = nil
			M.board_state.windows = {}
			M.board_state.buffers = {}
			M.board_state.line_mappings = {}
			M.board_state.lane_start_lines = {}
		end,
	})

	-- Auto-resize board on VimResized
	local resize_group = vim.api.nvim_create_augroup("todo_kanban_resize", { clear = true })
	vim.api.nvim_create_autocmd("VimResized", {
		group = resize_group,
		callback = function()
			if M.board_state.board_win and M.board_state.board_win:valid() then
				local new_total_w = vim.o.columns
				local new_total_h = vim.o.lines
				local new_statusline_h = (vim.o.laststatus > 0) and 1 or 0
				local new_tabline_h = (vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1)) and 1 or 0
				local new_cmd_h = vim.o.cmdheight
				local new_usable_h = new_total_h - new_cmd_h - new_statusline_h - new_tabline_h

				local new_board_w = math.max(40, math.min(new_total_w - 4, math.floor(new_total_w * 0.96)))
				if (new_total_w - new_board_w) % 2 ~= 0 then
					new_board_w = new_board_w - 1
				end

				local new_board_h = math.max(15, math.min(new_usable_h - 4, math.floor(new_usable_h * 0.88)))
				if (new_usable_h - new_board_h) % 2 ~= 0 then
					new_board_h = new_board_h - 1
				end

				local new_row = (new_usable_h - new_board_h) / 2
				local new_col = (new_total_w - new_board_w) / 2

				vim.api.nvim_win_set_config(M.board_state.board_win.win, {
					width = new_board_w,
					height = new_board_h,
					row = new_row,
					col = new_col,
				})

				local focus_col = get_current_column_name() or "GROUPING"
				M.recreate_column_windows(new_board_w, new_board_h, focus_col)
				M.render_board()
			end
		end,
	})

	M.board_state.scroll_index = 1
	local columns, _ = M.get_columns()
	local first_status_col = columns[2] or "GROUPING"
	M.recreate_column_windows(board_w, board_h, first_status_col)

	-- Render cards and lanes
	M.render_board()
end

return M
