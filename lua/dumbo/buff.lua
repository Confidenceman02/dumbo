local M = {}

---Checks if the given buffer is a genuine project file buffer.
---@param bufnr number
---@return boolean
function M.is_valid_project_buffer(bufnr)
	-- 1. Ignore unlisted buffers (Telescope prompts, popups, floating windows)
	if not vim.api.nvim_get_option_value("buflisted", { buf = bufnr }) then
		return false
	end

	-- 2. Must be a normal file buffer (reject "prompt", "nofile", "quickfix", "terminal")
	local buftype = vim.api.nvim_get_option_value("buftype", { buf = bufnr })
	if buftype ~= "" then
		return false
	end

	-- 3. Reject read-only or non-modifiable scratch buffers
	if not vim.api.nvim_get_option_value("modifiable", { buf = bufnr }) then
		return false
	end

	-- 4. Must have an actual file path on disk
	local bufname = vim.api.nvim_buf_get_name(bufnr)
	if bufname == "" then
		return false
	end

	-- 5. Must reside within the current working directory / project root
	local cwd = vim.fs.normalize(vim.fn.getcwd())
	local normalized_buf = vim.fs.normalize(bufname)
	if not vim.startswith(normalized_buf, cwd) then
		return false
	end

	return true
end

return M
