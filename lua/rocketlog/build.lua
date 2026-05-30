local config = require("rocketlog.config")

local M = {}

local WRAPPED_BLOCK_PAIRS = {
	["{"] = "}",
	["["] = "]",
	["("] = ")",
}


local function trim_blank_edges(lines)
	local start_index = 1
	local end_index = #lines

	while start_index <= end_index and not lines[start_index]:match("%S") do
		start_index = start_index + 1
	end

	while end_index >= start_index and not lines[end_index]:match("%S") do
		end_index = end_index - 1
	end

	local trimmed_lines = {}
	for index = start_index, end_index do
		table.insert(trimmed_lines, lines[index])
	end

	return trimmed_lines
end

local function leading_indent_width(line)
	local indent = line:match("^(%s*)") or ""
	return #indent
end

local function strip_indent(line, width)
	if not line:match("%S") then
		return ""
	end

	return line:sub(width + 1)
end

local function minimum_nonblank_indent(lines)
	local minimum_indent_width

	for _, line in ipairs(lines) do
		if line:match("%S") then
			local indent_width = leading_indent_width(line)
			if minimum_indent_width == nil or indent_width < minimum_indent_width then
				minimum_indent_width = indent_width
			end
		end
	end

	return minimum_indent_width
end

local function strip_common_indent(lines)
	local common_indent_width = minimum_nonblank_indent(lines)
	if not common_indent_width or common_indent_width == 0 then
		return vim.deepcopy(lines)
	end

	local dedented_lines = {}
	for _, line in ipairs(lines) do
		table.insert(dedented_lines, strip_indent(line, common_indent_width))
	end

	return dedented_lines
end

local function trim_left(line)
	return (line or ""):gsub("^%s*", "")
end

local function is_wrapped_block(first_text, last_text)
	return WRAPPED_BLOCK_PAIRS[first_text] == last_text
end

local function middle_lines(lines)
	local items = {}
	for index = 2, #lines - 1 do
		table.insert(items, lines[index])
	end

	return items
end

local function normalize_wrapped_block_lines(lines)
	local first_text = trim_left(lines[1])
	local last_text = trim_left(lines[#lines])

	if not is_wrapped_block(first_text, last_text) then
		return lines
	end

	local normalized_block_lines = { first_text }
	local middle_indent_width = minimum_nonblank_indent(middle_lines(lines))

	for index = 2, #lines - 1 do
		local line = lines[index] or ""
		if not line:match("%S") then
			table.insert(normalized_block_lines, "")
		else
			local rebased_line = line
			if middle_indent_width and middle_indent_width > 0 then
				rebased_line = strip_indent(line, middle_indent_width)
			end
			table.insert(normalized_block_lines, "  " .. rebased_line)
		end
	end

	table.insert(normalized_block_lines, last_text)
	return normalized_block_lines
end

local function dedent_lines_smart(lines)
	local trimmed_lines = trim_blank_edges(lines)
	if #trimmed_lines <= 1 then
		return trimmed_lines
	end

	return normalize_wrapped_block_lines(strip_common_indent(trimmed_lines))
end

local function normalize_label_text_single_line(expression)
	return expression:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function escape_string_text(text)
	return text:gsub("\\", "\\\\"):gsub('"', '\\"')
end

local function build_single_line_log(console_method, file, line_number, expression)
	local label_text = normalize_label_text_single_line(expression)

	if not config.get_show_prefix() then
		return {
			string.format(
				'console.%s("%s", %s);',
				console_method,
				escape_string_text(label_text),
				expression
			),
		}
	end

	return {
		string.format(
			'console.%s("%s:%d | %s", %s);',
			console_method,
			file,
			line_number,
			escape_string_text(label_text),
			expression
		),
	}
end

local function build_multiline_log(console_method, file, line_number, expression_lines)
	local normalized_expression_lines = dedent_lines_smart(expression_lines)
	local joined_label = table.concat(normalized_expression_lines, " ")
	local label_text = normalize_label_text_single_line(joined_label)

	local label_string
	if not config.get_show_prefix() then
		label_string = string.format('"%s"', escape_string_text(label_text))
	else
		label_string = string.format('"%s:%d | %s"', file, line_number, escape_string_text(label_text))
	end

	-- First arg is the label string, second arg spans multiple lines.
	local first_expr_line = normalized_expression_lines[1]
	local output_lines = {
		string.format("console.%s(%s, %s", console_method, label_string, first_expr_line),
	}

	for i = 2, #normalized_expression_lines do
		local expr_line = normalized_expression_lines[i]
		if i == #normalized_expression_lines then
			table.insert(output_lines, "  " .. expr_line .. ");")
		else
			table.insert(output_lines, "  " .. expr_line)
		end
	end

	return output_lines
end

---Build the console statement line(s) for the selected expression.
---If the expression spans multiple lines, emits a multiline console call that preserves expression formatting.
---@param file string Filename only (not full path)
---@param line_num integer Source line number used in the rocket label
---@param expr string Expression text captured from motions selection
---@param log_type string|nil Optional console method (log, error, warn, info, etc.)
---@return string[]
function M.build_rocket_log_lines(file, line_num, expr, log_type)
	local console_method = log_type or "log"
	local expression_lines = vim.split(expr, "\n", { plain = true })

	if #expression_lines == 1 then
		return build_single_line_log(console_method, file, line_num, expr)
	end

	return build_multiline_log(console_method, file, line_num, expression_lines)
end

return M
