local M = {}

local config = require("rocketlog.config")

---Open a Telescope picker that lists only RocketLog entries in the current project.
---The search query is fixed to the RocketLog marker so users cannot change the
---underlying grep pattern from this picker.
---@param opts table|nil Optional Telescope picker options (theme, cwd, layout, etc.)
---@return nil
function M.find_logs(opts)
	local ok, Snacks = pcall(require, "snacks")
	if not ok or not Snacks.picker then
		vim.notify("snacks.nvim picker is not available", vim.log.levels.WARN)
		return
	end

	local search_pattern
	if config.get_show_prefix() then
		search_pattern = "[" .. config.get_label() .. "]"
	else
		search_pattern = "console\\.\\w+\\(`[^`]+:\\d+ \\|"
	end

	Snacks.picker.pick({
		source = "grep",
		title = "RocketLog",
		search = search_pattern,
		live = false,
		regex = not config.get_show_prefix(),
	})
end

return M
