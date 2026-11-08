---@diagnostic disable: duplicate-set-field
local dumbo = require("dumbo")
local client = require("dumbo.client")
local ghost_text = require("dumbo.ghost_text")
local buff = require("dumbo.buff")

describe("dumbo.trigger", function()
	local bufnr
	local orig_request
	local mock_completion
	local mock_err

	before_each(function()
		bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		dumbo.setup({ debounce_ms = 10 })

		mock_completion = " pass"
		mock_err = nil

		-- Intercept networking to test trigger synchronously
		orig_request = client.request_completion
		client.request_completion = function(prompt, opts, cfg, cb)
			cb(mock_completion, mock_err)
		end
	end)

	after_each(function()
		client.request_completion = orig_request
		dumbo.dismiss()
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end
	end)

	it("does nothing when not in insert mode", function()
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "def foo():" })
		vim.api.nvim_win_set_cursor(0, { 1, 10 })

		-- In headless tests, mode is 'n' (normal mode)
		dumbo.trigger()

		-- ghost_text should never have been displayed
		assert.is_nil(ghost_text.get_current())
	end)

	it("shows ghost text when triggered in insert mode", function()
		-- Adding a trailing space makes line length 11, so col 10 is valid
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "def foo(): " })
		vim.api.nvim_win_set_cursor(0, { 1, 10 })

		local orig_get_mode = vim.api.nvim_get_mode
		vim.api.nvim_get_mode = function()
			return { mode = "i", blocking = false }
		end

		dumbo.trigger()

		vim.api.nvim_get_mode = orig_get_mode

		local current = ghost_text.get_current()
		assert.is_not_nil(current)
		assert.are.same(" pass", current.text)
		assert.are.same(0, current.row)
		assert.are.same(10, current.col)
	end)

	it("shows ghost text when triggered in insert mode", function()
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "def foo():" })
		vim.api.nvim_win_set_cursor(0, { 1, 10 })

		-- Temporarily stub mode check to simulate insert mode
		local orig_get_mode = vim.api.nvim_get_mode
		vim.api.nvim_get_mode = function()
			return { mode = "i", blocking = false }
		end

		dumbo.trigger()

		vim.api.nvim_get_mode = orig_get_mode

		local current = ghost_text.get_current()
		assert.is_not_nil(current)
		assert.are.same(" pass", current.text)
		assert.are.same(0, current.row)
		assert.are.same(9, current.col)
	end)

	it("aborts rendering if cursor moved while request was pending", function()
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "def foo():", "    x = 1" })
		vim.api.nvim_win_set_cursor(0, { 1, 10 })

		local orig_get_mode = vim.api.nvim_get_mode
		vim.api.nvim_get_mode = function()
			return { mode = "i", blocking = false }
		end

		-- Simulate async delay where cursor moves before the callback resolves
		client.request_completion = function(prompt, opts, cfg, cb)
			-- User moved cursor to line 2, col 4 while waiting
			vim.api.nvim_win_set_cursor(0, { 2, 4 })
			cb(" pass", nil)
		end

		dumbo.trigger()

		vim.api.nvim_get_mode = orig_get_mode

		-- Should reject stale completion because cursor coordinates changed
		assert.is_nil(ghost_text.get_current())
	end)

	it("does not render when client returns an error", function()
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "def foo():" })
		vim.api.nvim_win_set_cursor(0, { 1, 10 })

		local orig_get_mode = vim.api.nvim_get_mode
		vim.api.nvim_get_mode = function()
			return { mode = "i", blocking = false }
		end

		mock_completion = nil
		mock_err = "vLLM connection refused"

		dumbo.trigger()

		vim.api.nvim_get_mode = orig_get_mode

		assert.is_nil(ghost_text.get_current())
	end)
end)

describe("dumbo typing integration", function()
	local bufnr
	local orig_request
	local orig_mode

	before_each(function()
		bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		-- Fill with enough ASCII characters so col 1, 2, 5 etc. never clamp in Normal mode
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x_padding_line" })
		vim.api.nvim_win_set_cursor(0, { 1, 1 })

		-- Fast debounce for test speed
		dumbo.setup({
			debounce_ms = 20,
		})

		-- Stub network request
		orig_request = client.request_completion
		client.request_completion = function(prompt, opts, cfg, cb)
			cb(" = 42", nil)
		end

		-- Stub buf check
		buff.is_valid_project_buffer = function()
			return true
		end

		-- Stub get_mode to simulate insert mode during tests
		orig_mode = vim.api.nvim_get_mode
		vim.api.nvim_get_mode = function()
			return { mode = "i", blocking = false }
		end
	end)

	after_each(function()
		if orig_mode then
			vim.api.nvim_get_mode = orig_mode
		end
		client.request_completion = orig_request
		dumbo.dismiss()
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end
	end)

	it("triggers completion automatically after debounce timer expires", function()
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x_padding_line" })
		vim.api.nvim_win_set_cursor(0, { 1, 1 })

		vim.api.nvim_exec_autocmds("TextChangedI", { buffer = bufnr })

		assert.is_nil(ghost_text.get_current())

		vim.wait(150, function()
			return ghost_text.get_current() ~= nil
		end, 10)

		local current = ghost_text.get_current()
		assert.is_not_nil(current)
		assert.are.same(" = 42", current.text)
		assert.are.same(0, current.row)
		assert.are.same(1, current.col)
	end)

	it("resets debounce timer on rapid sequential typing events", function()
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x_padding_line" })
		vim.api.nvim_win_set_cursor(0, { 1, 1 })

		vim.api.nvim_exec_autocmds("TextChangedI", { buffer = bufnr })

		vim.wait(10, function()
			return false
		end, 5)

		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "xy_padding_line" })
		vim.api.nvim_win_set_cursor(0, { 1, 2 })
		vim.api.nvim_exec_autocmds("TextChangedI", { buffer = bufnr })

		vim.wait(150, function()
			return ghost_text.get_current() ~= nil
		end, 10)

		local current = ghost_text.get_current()
		assert.is_not_nil(current)
		assert.are.same(2, current.col)
	end)

	it("clears ghost text when exiting insert mode (InsertLeave)", function()
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x_padding_line" })
		vim.api.nvim_win_set_cursor(0, { 1, 1 })

		vim.api.nvim_exec_autocmds("TextChangedI", { buffer = bufnr })

		vim.wait(150, function()
			return ghost_text.get_current() ~= nil
		end, 10)

		assert.is_not_nil(ghost_text.get_current())

		-- Restore actual mode before firing InsertLeave so it leaves insert mode cleanly
		vim.api.nvim_get_mode = orig_mode

		-- Fire InsertLeave autocommand
		vim.api.nvim_exec_autocmds("InsertLeave", { buffer = bufnr })

		-- Ghost text must be cleared by dismissal callback
		assert.is_nil(ghost_text.get_current())
	end)
end)
