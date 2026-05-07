local state_mod = require("rocketlog.dashboard.state")

local M = {}

local shell_ns = vim.api.nvim_create_namespace("rocketlog_dashboard_shell")
local list_ns = vim.api.nvim_create_namespace("rocketlog_dashboard_list")
local preview_ns = vim.api.nvim_create_namespace("rocketlog_dashboard_preview")

local HEADER_LABELS = { "CWD", "Source", "Scope", "Filter", "Files", "Logs", "Folded", "Selected" }
local HELP_KEYS = {
	"[<CR>/o]",
	"[v]",
	"[c/C]",
	"[/]",
	"[x]",
	"[t]",
	"[<Tab>/za/zo/zc]",
	"[zR]",
	"[zM]",
	"[d/D]",
	"[r/R]",
	"[?]",
	"[q/Esc]",
}

local function pad(text, width)
	text = text or ""
	if vim.fn.strdisplaywidth(text) > width then
		return vim.fn.strcharpart(text, 0, math.max(0, width - 1)) .. "…"
	end

	return text .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(text)))
end

local function total_entries(groups)
	local count = 0
	for _, group in ipairs(groups or {}) do
		count = count + #group.entries
	end
	return count
end

local function collapsed_count(state)
	local count = 0
	for _, group in ipairs(state.groups or {}) do
		if state.collapsed_paths[group.path] then
			count = count + 1
		end
	end
	return count
end

local function current_scope_label(state)
	return state.scope == "current_file" and "Current file" or "Project"
end

local function relative_path(path, cwd)
	local display_path = vim.fn.fnamemodify(path, ":.")
	if display_path == path and cwd and path:find(cwd, 1, true) == 1 then
		display_path = path:sub(#cwd + 2)
	end
	return display_path
end

local function log_type_highlight(log_type)
	local upper = (log_type or "log"):upper()
	if upper == "ERROR" then
		return "RocketLogDashboardError"
	end
	if upper == "WARN" then
		return "RocketLogDashboardWarn"
	end
	if upper == "INFO" then
		return "RocketLogDashboardInfo"
	end
	return "RocketLogDashboardLog"
end

local function selected_entry_summary(state)
	local entry = state_mod.get_selected_entry(state)
	if not entry then
		return "No log selected"
	end

	return string.format("%s:%d  %s", entry.filename, entry.lnum, entry.summary or entry.label)
end

local function render_plain_buffer(bufnr, lines)
	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false
end

local function blank_lines(width, height)
	local lines = {}
	for _ = 1, height do
		table.insert(lines, string.rep(" ", width))
	end
	return lines
end

local function highlight_occurrences(bufnr, namespace, line_number0, text, pattern, highlight_group)
	local start_index = 1
	while start_index <= #text do
		local start_col, end_col = text:find(pattern, start_index, true)
		if not start_col then
			break
		end

		vim.api.nvim_buf_add_highlight(bufnr, namespace, highlight_group, line_number0, start_col - 1, end_col)
		start_index = end_col + 1
	end
end

local function highlight_many(bufnr, namespace, line_number0, text, patterns, highlight_group)
	for _, pattern in ipairs(patterns) do
		highlight_occurrences(bufnr, namespace, line_number0, text, pattern, highlight_group)
	end
end

local function pad_to_height(lines, width, height)
	while #lines < height do
		table.insert(lines, string.rep(" ", width))
	end
	return lines
end

local function build_header_lines(state)
	local groups = state.groups or {}
	local source_path = state.source_path ~= "" and relative_path(state.source_path, state.cwd) or "[No Name]"
	local lines = {
		pad("CWD    " .. state.cwd, state.ui.header_width),
		pad("Source " .. source_path, state.ui.header_width),
		pad(
			string.format(
				"Scope %s   Filter %s   Files %d   Logs %d   Folded %d",
				current_scope_label(state),
				state.filter ~= "" and state.filter or "none",
				#groups,
				total_entries(groups),
				collapsed_count(state)
			),
			state.ui.header_width
		),
	}

	return pad_to_height(lines, state.ui.header_width, state.ui.header_height)
end

local function build_footer_lines(state)
	local lines = {
		pad("Open [<CR>/o]   Split [v]   Toggle [c]   Filter [/]   Clear [x]   Scope [t]", state.ui.help_width),
		pad("Fold [<Tab>]   Delete [d]   Refresh [r]   Help [?]   Close [q/Esc]", state.ui.help_width),
		pad("Selected " .. selected_entry_summary(state), state.ui.help_width),
	}

	return pad_to_height(lines, state.ui.help_width, state.ui.help_height)
end

local function highlight_header_lines(bufnr, lines)
	vim.api.nvim_buf_clear_namespace(bufnr, shell_ns, 0, -1)
	for line_number, text in ipairs(lines) do
		local line_number0 = line_number - 1
		vim.api.nvim_buf_add_highlight(bufnr, shell_ns, "RocketLogDashboardHeader", line_number0, 0, -1)
		highlight_many(bufnr, shell_ns, line_number0, text, HEADER_LABELS, "RocketLogDashboardMetaLabel")
	end
end

local function highlight_footer_lines(bufnr, lines)
	vim.api.nvim_buf_clear_namespace(bufnr, shell_ns, 0, -1)
	for line_number, text in ipairs(lines) do
		local line_number0 = line_number - 1
		vim.api.nvim_buf_add_highlight(bufnr, shell_ns, "RocketLogDashboardFooter", line_number0, 0, -1)
		highlight_many(bufnr, shell_ns, line_number0, text, HEADER_LABELS, "RocketLogDashboardMetaLabel")
		highlight_many(bufnr, shell_ns, line_number0, text, HELP_KEYS, "RocketLogDashboardHintKey")
	end
end

---@param state table
function M.render_shell(state)
	render_plain_buffer(state.ui.root_buf, blank_lines(state.ui.width, state.ui.height))

	local header_lines = build_header_lines(state)
	render_plain_buffer(state.ui.header_buf, header_lines)
	highlight_header_lines(state.ui.header_buf, header_lines)

	local footer_lines = build_footer_lines(state)
	render_plain_buffer(state.ui.help_buf, footer_lines)
	highlight_footer_lines(state.ui.help_buf, footer_lines)
end

local function format_entry_line(entry)
	local line_range = entry.end_lnum > entry.lnum and string.format("%d-%d", entry.lnum, entry.end_lnum)
		or tostring(entry.lnum)

	return string.format(
		"  %6s  %-5s %s%s%s",
		line_range,
		(entry.log_type or "log"):upper(),
		entry.commented and "[off] " or "",
		entry.stale and "* " or "",
		entry.summary or entry.label
	)
end

local function build_list_lines(state)
	local lines = {}
	local line_map = {}
	local groups = state.groups or {}

	if #groups == 0 then
		return {
			"No RocketLogs found.",
			"",
			"Try switching scope with t or clear the filter with x.",
		}, line_map
	end

	for _, group in ipairs(groups) do
		local is_collapsed = state.collapsed_paths[group.path] == true
		local group_icon = is_collapsed and "▸" or "▾"
		local group_line = string.format("%s %s (%d)", group_icon, relative_path(group.path, state.cwd), group.count)
		table.insert(lines, pad(group_line, state.ui.list_width))
		line_map[#lines] = { kind = "group", group = group }

		if not is_collapsed then
			for _, entry in ipairs(group.entries) do
				table.insert(lines, pad(format_entry_line(entry), state.ui.list_width))
				line_map[#lines] = { kind = "entry", entry = entry, group = group }
			end
		end

		table.insert(lines, "")
	end

	return lines, line_map
end

local function highlight_group_row(bufnr, line_number0)
	vim.api.nvim_buf_add_highlight(bufnr, list_ns, "RocketLogDashboardFoldIcon", line_number0, 0, 3)
	vim.api.nvim_buf_add_highlight(bufnr, list_ns, "RocketLogDashboardGroup", line_number0, 2, -1)
end

local function highlight_entry_row(bufnr, line_number0, line_text, entry)
	vim.api.nvim_buf_add_highlight(bufnr, list_ns, "RocketLogDashboardLineNr", line_number0, 2, 8)
	vim.api.nvim_buf_add_highlight(bufnr, list_ns, log_type_highlight(entry.log_type), line_number0, 10, 15)

	if entry.commented then
		highlight_occurrences(bufnr, list_ns, line_number0, line_text, "[off]", "RocketLogDashboardDisabled")
	end
	if entry.stale then
		highlight_occurrences(bufnr, list_ns, line_number0, line_text, "*", "RocketLogDashboardStale")
	end
end

local function highlight_list_rows(state, lines)
	vim.api.nvim_buf_clear_namespace(state.ui.list_buf, list_ns, 0, -1)

	for line_number, item in pairs(state.line_map) do
		local line_number0 = line_number - 1
		if item.kind == "group" then
			highlight_group_row(state.ui.list_buf, line_number0)
		else
			highlight_entry_row(state.ui.list_buf, line_number0, lines[line_number], item.entry)
		end
	end
end

---@param state table
function M.render_list(state)
	local lines, line_map = build_list_lines(state)
	state.line_map = line_map
	state.list_line_count = #lines

	vim.bo[state.ui.list_buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.ui.list_buf, 0, -1, false, lines)
	highlight_list_rows(state, lines)
	vim.bo[state.ui.list_buf].modifiable = false
	pcall(vim.api.nvim_win_set_cursor, state.ui.list_win, { state_mod.find_preferred_cursor_row(state), 0 })
end

local function read_preview_source_lines(entry)
	if entry.bufnr and vim.api.nvim_buf_is_valid(entry.bufnr) then
		return vim.api.nvim_buf_get_lines(entry.bufnr, 0, -1, false)
	end

	local ok_read, disk_lines = pcall(vim.fn.readfile, entry.path)
	return ok_read and disk_lines or { "Unable to read preview for " .. entry.path }
end

local function build_preview_lines(state, entry)
	if not entry then
		vim.bo[state.ui.preview_buf].filetype = "text"
		return {
			"No preview available.",
			"",
			"Select a RocketLog entry to inspect the surrounding code.",
		}, nil, nil
	end

	local source_lines = read_preview_source_lines(entry)
	local preview_context = state.preview_context or 4
	local context_start = math.max(1, entry.lnum - preview_context)
	local context_end = math.min(#source_lines, entry.end_lnum + preview_context)
	local gutter_width = math.max(3, #tostring(context_end))
	local lines = {
		"File: " .. relative_path(entry.path, state.cwd),
		string.format(
			"Range: %d%s   Type: %s   Commented: %s   Stale: %s",
			entry.lnum,
			entry.end_lnum > entry.lnum and ("-" .. entry.end_lnum) or "",
			(entry.log_type or "log"):upper(),
			entry.commented and "yes" or "no",
			entry.stale and "yes" or "no"
		),
		"Summary: " .. (entry.summary or entry.label),
		string.rep("─", math.max(1, state.ui.preview_width)),
	}

	for line_number = context_start, context_end do
		local prefix = string.format("%" .. gutter_width .. "d │ ", line_number)
		table.insert(lines, prefix .. source_lines[line_number])
	end

	local target_start = 5 + (entry.lnum - context_start)
	local target_end = target_start + (entry.end_lnum - entry.lnum)
	vim.bo[state.ui.preview_buf].filetype = entry.filetype or "text"

	return lines, target_start, target_end
end

local function highlight_preview_lines(state, lines, target_start, target_end)
	vim.api.nvim_buf_clear_namespace(state.ui.preview_buf, preview_ns, 0, -1)

	for line_number = 1, math.min(4, #lines) do
		vim.api.nvim_buf_add_highlight(
			state.ui.preview_buf,
			preview_ns,
			"RocketLogDashboardPreviewMeta",
			line_number - 1,
			0,
			-1
		)
	end

	if target_start and target_end then
		for line_number = target_start, target_end do
			vim.api.nvim_buf_add_highlight(
				state.ui.preview_buf,
				preview_ns,
				"RocketLogDashboardPreviewTarget",
				line_number - 1,
				0,
				-1
			)
		end
	end
end

---@param state table
function M.render_preview(state)
	local entry = state_mod.get_selected_entry(state)
	local lines, target_start, target_end = build_preview_lines(state, entry)

	vim.bo[state.ui.preview_buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.ui.preview_buf, 0, -1, false, lines)
	highlight_preview_lines(state, lines, target_start, target_end)
	vim.bo[state.ui.preview_buf].modifiable = false
	pcall(vim.api.nvim_win_set_cursor, state.ui.preview_win, { math.max(1, target_start or 1), 0 })
end

---@param state table
function M.refresh(state)
	M.render_shell(state)
	M.render_list(state)
	M.render_preview(state)
end

return M
