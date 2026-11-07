local M = {}

---Dedicated namespace for dumbo ghost text to avoid clashing with LSP or diagnostics.
local NS_ID = vim.api.nvim_create_namespace("dumbo_ghost_text")

---Highlight group used for virtual ghost text.
---Defaults to Neovim's standard 'Comment' highlight for dimmed text.
M.HIGHLIGHT_GROUP = "Comment"

---@class DumboSuggestion
---@field bufnr integer Buffer number where suggestion is rendered
---@field row integer 0-indexed line number
---@field col integer 0-indexed byte column
---@field text string Completion string
---@field extmark_id integer Extmark ID returned by Neovim

---@type DumboSuggestion|nil
local current_suggestion = nil

---Returns the currently active suggestion state, if any.
---@return DumboSuggestion|nil
function M.get_current()
	return current_suggestion
end

---Clears any currently active ghost text extmark and resets suggestion state.
---Can be called safely even when no ghost text is active.
function M.clear()
	if current_suggestion then
		if current_suggestion.extmark_id and vim.api.nvim_buf_is_valid(current_suggestion.bufnr) then
			pcall(vim.api.nvim_buf_del_extmark, current_suggestion.bufnr, NS_ID, current_suggestion.extmark_id)
		end
		current_suggestion = nil
	end
end

---Renders ghost text inline directly following the cursor position.
---@param bufnr integer
---@param row integer 0-indexed row
---@param col integer 0-indexed byte column
---@param text string The completion text to render
---@return integer|nil extmark_id Returns the extmark ID, or nil if invalid input
function M.show(bufnr, row, col, text)
	M.clear()
	-- Clear any previously rendered ghost text before showing a new one

	if not text or text == "" then
		return nil
	end

	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end

	local extmark_id = vim.api.nvim_buf_set_extmark(bufnr, NS_ID, row, col, {
		virt_text = { { text, M.HIGHLIGHT_GROUP } },
		virt_text_pos = "inline",
		hl_mode = "combine",
	})

	current_suggestion = {
		bufnr = bufnr,
		row = row,
		col = col,
		text = text,
		extmark_id = extmark_id,
	}

	return extmark_id
end

---Accepts the current ghost text suggestion, inserting it into the buffer
---and positioning the cursor at the end of the inserted text.
---@return boolean accepted Returns true if suggestion was applied, false otherwise
function M.accept()
	local suggestion = current_suggestion
	if not suggestion then
		return false
	end

	if not vim.api.nvim_buf_is_valid(suggestion.bufnr) then
		M.clear()
		return false
	end

	local bufnr = suggestion.bufnr
	local row = suggestion.row
	local col = suggestion.col
	local text = suggestion.text

	-- 1. Wipe virtual text extmark and clear state
	M.clear()

	-- 2. Splice the completion text directly into the buffer at (row, col)
	-- nvim_buf_set_text takes: bufnr, start_row, start_col, end_row, end_col, replacement_lines
	-- Since we are inserting at a single point without replacing existing code,
	-- start and end coordinates are identical.
	local ok = pcall(vim.api.nvim_buf_set_text, bufnr, row, col, row, col, { text })
	if not ok then
		return false
	end

	-- 3. Reposition cursor at the end of the newly inserted text if currently in that window
	local current_buf = vim.api.nvim_get_current_buf()
	if current_buf == bufnr then
		-- Cursor row is 1-indexed for nvim_win_set_cursor, col is 0-indexed byte offset
		local new_col = col + #text
		pcall(vim.api.nvim_win_set_cursor, 0, { row + 1, new_col })
	end

	return true
end

return M
