local comment = require("rocketlog.comment")
local config = require("rocketlog.config")

local M = {}

local function escape_lua_pattern(text)
	return (text:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

local function build_location_patterns(marker_label)
	local escaped_label = escape_lua_pattern(marker_label)

	return {
		-- Legacy rocket format: `🚀[LABEL] ~ file.ts:42 ~ var:`
		"(`🚀%[" .. escaped_label .. "%]%s*~%s*)[^:]+:%d+(%s*~%s*)",
		"(`🚀%s*~%s*)[^:]+:%d+(%s*~%s*)",
		-- New prefix format: "file.ts:42 | var" — capture quote, replace file:linenum before pipe
		'(")[^"|]+:%d+(%s*|)',
	}
end

local function line_is_refreshable(line_text, bufnr)
	return not comment.is_commented_line(line_text, {
		bufnr = bufnr,
		filetype = vim.bo[bufnr].filetype,
		path = vim.api.nvim_buf_get_name(bufnr),
	})
end

local function replace_embedded_location(line_text, filename, line_number, patterns)
	for _, pattern in ipairs(patterns) do
		local updated_line, replacements = line_text:gsub(pattern, "%1" .. filename .. ":" .. line_number .. "%2", 1)
		if replacements > 0 then
			return updated_line, replacements
		end
	end

	return line_text, 0
end

---Update RocketLog labels (filename + line number) in the current buffer.
---This only updates logs that match the standard RocketLog format:
---console.log(`🚀[ROCKETLOG] ~ file.ts:123 ~ label:`, ...)
function M.refresh_buffer()
	local bufnr = vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local filename = vim.fn.expand("%:t")
	local location_patterns = build_location_patterns(config.get_label())
	local changed_count = 0

	for line_number, line_text in ipairs(lines) do
		if line_is_refreshable(line_text, bufnr) then
			local updated_line, replacements = replace_embedded_location(
				line_text,
				filename,
				line_number,
				location_patterns
			)

			if replacements > 0 and updated_line ~= line_text then
				lines[line_number] = updated_line
				changed_count = changed_count + 1
			end
		end
	end

	if changed_count > 0 then
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	end

	return changed_count
end

return M
