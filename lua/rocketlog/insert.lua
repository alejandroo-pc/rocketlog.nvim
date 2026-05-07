local M = {}

local CONTINUATION_PREFIX_PATTERNS = {
	"^,",
	"^},",
	"^%],",
	"^%),",
	"^%.",
	"^%?%.",
	"^%?%?",
	"^&&",
	"^||",
	"^%+",
	"^-",
	"^%*",
	"^/",
	"^%%",
}

local function trim_right(text)
	return (text or ""):gsub("%s+$", "")
end

local function trim_left(text)
	return (text or ""):gsub("^%s+", "")
end

local function get_indent_unit()
	local shiftwidth = vim.bo.shiftwidth
	if not shiftwidth or shiftwidth < 1 then
		shiftwidth = vim.bo.tabstop
	end
	if not shiftwidth or shiftwidth < 1 then
		shiftwidth = 2
	end

	if vim.bo.expandtab == false then
		return "	"
	end

	return string.rep(" ", shiftwidth)
end

local function get_config_flag(flag_name, default)
	local ok_config, cfg = pcall(require, "rocketlog.config")
	if not ok_config or not cfg or not cfg.config then
		return default
	end

	return cfg.config[flag_name] ~= false
end

local function get_line_indent(line_number)
	if not line_number or line_number < 1 then
		return ""
	end

	local line_text = vim.fn.getline(line_number) or ""
	return line_text:match("^%s*") or ""
end

local function apply_indent(lines, indent)
	local indented_lines = {}
	for _, line in ipairs(lines) do
		if line == "" then
			table.insert(indented_lines, "")
		else
			table.insert(indented_lines, indent .. line)
		end
	end
	return indented_lines
end

local function next_nonblank_line(from_line, last_buffer_line)
	for line_number = from_line + 1, last_buffer_line do
		local line_text = vim.fn.getline(line_number)
		if line_text and line_text:match("%S") then
			return line_number, line_text
		end
	end
	return nil, nil
end

local function line_ends_with_comma(text)
	return trim_right(text):match(",$") ~= nil
end

local function is_continuation_line(text)
	if not text then
		return false
	end

	local trimmed_left = text:gsub("^%s+", "")
	for _, pattern in ipairs(CONTINUATION_PREFIX_PATTERNS) do
		if trimmed_left:match(pattern) then
			return true
		end
	end

	return false
end

---@param context table|nil
---@return table|nil, string|nil
local function try_treesitter_target(context)
	if not get_config_flag("prefer_treesitter", true) or not context then
		return nil, not context and nil or "treesitter_disabled"
	end

	local ok_treesitter, treesitter = pcall(require, "rocketlog.treesitter")
	if not ok_treesitter or not treesitter then
		return nil
	end

	return treesitter.resolve_insertion({
		bufnr = 0,
		start_row = context.start_row0,
		start_col = context.start_col0 or 0,
		end_row = context.end_row0,
		end_col = context.end_col0 or context.start_col0 or 0,
	})
end

---@param start_line integer
---@return integer
function M.find_log_line_number(start_line)
	local last_buffer_line = vim.fn.line("$")
	local insertion_line = start_line
	local paren_depth, brace_depth, bracket_depth = 0, 0, 0
	local saw_multiline_structure = false

	for line_number = start_line, last_buffer_line do
		local line_text = vim.fn.getline(line_number)

		for char_index = 1, #line_text do
			local char = line_text:sub(char_index, char_index)
			if char == "(" then
				paren_depth = paren_depth + 1
				saw_multiline_structure = true
			elseif char == ")" then
				paren_depth = math.max(0, paren_depth - 1)
			elseif char == "{" then
				brace_depth = brace_depth + 1
				saw_multiline_structure = true
			elseif char == "}" then
				brace_depth = math.max(0, brace_depth - 1)
			elseif char == "[" then
				bracket_depth = bracket_depth + 1
				saw_multiline_structure = true
			elseif char == "]" then
				bracket_depth = math.max(0, bracket_depth - 1)
			end
		end

		local compact_line = line_text:gsub("%s+", "")
		local _, next_nonblank_text = next_nonblank_line(line_number, last_buffer_line)
		local structure_closed = saw_multiline_structure and paren_depth == 0 and brace_depth == 0 and bracket_depth == 0

		if line_text:find(";") and paren_depth == 0 and brace_depth == 0 and bracket_depth == 0 then
			insertion_line = line_number
			break
		end

		if structure_closed then
			if line_ends_with_comma(line_text) or is_continuation_line(next_nonblank_text) then
				goto continue
			end

			insertion_line = line_number
			break
		end

		if line_number == start_line and not saw_multiline_structure and compact_line ~= "" then
			if line_ends_with_comma(line_text) or is_continuation_line(next_nonblank_text) then
				goto continue
			end

			insertion_line = line_number
			break
		end

		::continue::
	end

	return insertion_line + 1
end

local function insert_lines_at(lines_to_insert, insert_at_1_based)
	vim.api.nvim_buf_set_lines(0, insert_at_1_based - 1, insert_at_1_based - 1, false, lines_to_insert)
	return insert_at_1_based
end

local function get_block_body_indent(ts_target)
	local base_indent = get_line_indent(ts_target.block_start_line)
	if ts_target.reference_line and ts_target.reference_line > ts_target.block_start_line then
		local reference_indent = get_line_indent(ts_target.reference_line)
		if reference_indent ~= "" then
			return reference_indent
		end
	end

	if ts_target.block_start_line == ts_target.block_end_line then
		return base_indent .. "  "
	end

	return base_indent .. get_indent_unit()
end

local function insert_inside_block_start(log_lines, ts_target)
	local block_start_line = ts_target.block_start_line
	local block_end_line = ts_target.block_end_line
	local block_start_col0 = ts_target.block_start_col or 0
	local block_end_col0 = ts_target.block_end_col or block_start_col0
	local start_line_text = vim.fn.getline(block_start_line) or ""
	local body_indent = get_block_body_indent(ts_target)
	local indented_log_lines = apply_indent(log_lines, body_indent)

	if block_start_line == block_end_line then
		local prefix = start_line_text:sub(1, block_start_col0 + 1)
		local inside_text = start_line_text:sub(block_start_col0 + 2, math.max(block_start_col0 + 1, block_end_col0 - 1))
		local suffix = start_line_text:sub(block_end_col0 + 1)
		local replacement_lines = { prefix }
		local trimmed_inside = trim_left(trim_right(inside_text))
		local base_indent = get_line_indent(block_start_line)

		vim.list_extend(replacement_lines, indented_log_lines)
		if trimmed_inside ~= "" then
			table.insert(replacement_lines, body_indent .. trimmed_inside)
		end
		table.insert(replacement_lines, base_indent .. "}" .. suffix)

		vim.api.nvim_buf_set_lines(0, block_start_line - 1, block_start_line, false, replacement_lines)
		return block_start_line + 1
	end

	local remainder_after_open = trim_left(start_line_text:sub(block_start_col0 + 2))
	if remainder_after_open ~= "" then
		local prefix = start_line_text:sub(1, block_start_col0 + 1)
		local replacement_lines = { prefix }
		vim.list_extend(replacement_lines, indented_log_lines)
		table.insert(replacement_lines, body_indent .. remainder_after_open)
		vim.api.nvim_buf_set_lines(0, block_start_line - 1, block_start_line, false, replacement_lines)
		return block_start_line + 1
	end

	local insert_line = ts_target.insert_line or block_end_line
	if insert_line <= block_start_line then
		insert_line = block_start_line + 1
	end

	return insert_lines_at(indented_log_lines, insert_line)
end

---@param log_line string|string[]
---@param start_line integer
---@param context table|nil
---@return integer|nil, string|nil
function M.insert_after_statement(log_line, start_line, context)
	local log_lines = type(log_line) == "table" and log_line or { log_line }
	local ts_target, ts_error = try_treesitter_target(context)

	if ts_target then
		if ts_target.mode == "inside_block_start" then
			return insert_inside_block_start(log_lines, ts_target)
		end

		if ts_target.line then
			local reference_line = ts_target.reference_line or ts_target.line
			local indented_lines = apply_indent(log_lines, get_line_indent(reference_line))
			local insert_at = ts_target.mode == "after" and (ts_target.line + 1) or ts_target.line
			return insert_lines_at(indented_lines, insert_at)
		end
	end

	if ts_error == "implicit_arrow_body" or ts_error == "selection_in_function_header" then
		return nil, ts_error
	end

	if not get_config_flag("fallback_to_heuristics", true) then
		return nil, ts_error or "no_insertion_target"
	end

	local fallback_insert_line = M.find_log_line_number(start_line)
	local fallback_indent = get_line_indent(start_line)
	return insert_lines_at(apply_indent(log_lines, fallback_indent), fallback_insert_line), ts_error
end

---@param anchor_line integer|nil
---@param selection_start_line integer
---@return integer
function M.normalize_anchor_line(anchor_line, selection_start_line)
	local resolved_anchor_line = anchor_line or selection_start_line
	if not resolved_anchor_line or resolved_anchor_line < 1 then
		return selection_start_line
	end

	local previous_line_text = vim.fn.getline(resolved_anchor_line - 1)
	local current_line_text = vim.fn.getline(resolved_anchor_line)
	if not (resolved_anchor_line > 1 and previous_line_text and current_line_text) then
		return resolved_anchor_line
	end

	local previous_trimmed = previous_line_text:gsub("%s+$", "")
	local current_trimmed = current_line_text:gsub("^%s+", "")
	local previous_opens_container = previous_trimmed:find("{%s*$") or previous_trimmed:find("%(%s*$") or previous_trimmed:find("%[%s*$")
	local current_starts_assignment = current_trimmed:match("^[%w_]+%s*=")
		or current_trimmed:match("^const%s+")
		or current_trimmed:match("^let%s+")

	if previous_opens_container and not current_starts_assignment then
		return resolved_anchor_line - 1
	end

	return resolved_anchor_line
end

return M
