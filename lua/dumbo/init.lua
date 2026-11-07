local fim = require("dumbo.fim")
local client = require("dumbo.client")
local ghost_text = require("dumbo.ghost_text")
local logger = require("dumbo.log")
local buff = require("dumbo.buff")

local M = {}

---@class DumboDebugLog
---@field enabled boolean Whether debugging is enabled or not
---@field log_file string Path to the debug log file file

---@class DumboConfig
---@field debounce_ms integer Milliseconds to wait after typing stops before querying (default: 150)
---@field max_prefix_lines integer Maximum lines above cursor to feed into prefix context (default: 100)
---@field max_suffix_lines integer Maximum lines below cursor to feed into suffix context (default: 50)
---@field client DumboClientConfig Network and vLLM configuration
---@field payload DumboDefaultPayload Model inference parameters
---@field debug DumboDebugLog Debugging options

---@type DumboConfig
M.defaults = {
	debounce_ms = 150,
	max_prefix_lines = 100,
	max_suffix_lines = 50,
	client = client.DEFAULT_CONFIG,
	payload = fim.DEFAULT_PAYLOAD,
	debug = {
		enabled = false,
		log_file = vim.fn.stdpath("state") .. "/dumbo.log", -- e.g. ~/.local/state/nvim/dumbo.log
	},
}

-- @type DumboConfig
M.config = vim.deepcopy(M.defaults)

---Internal state tracking
local timer = nil
local is_enabled = true
local augroup = vim.api.nvim_create_augroup("DumboAutocommands", { clear = true })

---Accepts the current ghost text suggestion.
---@return boolean accepted
function M.accept()
	return ghost_text.accept()
end

function M.dismiss()
	if timer and timer:is_active() then
		timer:stop()
	end
	client.cancel()
	ghost_text.clear()
end

---Toggles code completion on or off.
function M.toggle()
	is_enabled = not is_enabled
	if not is_enabled then
		M.dismiss()
	end
	local status = is_enabled and "enabled" or "disabled"
	vim.notify("Dumbo " .. status, vim.log.levels.INFO)
end

function M.trigger()
	if not is_enabled then
		return
	end

	ghost_text.clear()
	client.cancel()

	local mode = vim.api.nvim_get_mode().mode
	if mode ~= "i" and mode ~= "ic" and mode ~= "ix" then
		return
	end

	local bufnr = vim.api.nvim_get_current_buf()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row = cursor[1] -- 1-indexed row matching extract_context spec
	local col = cursor[2] -- 0-indexed byte column

	-- Extract context directly using fim module
	local prefix, suffix = fim.extract_context(bufnr, row, col, {
		max_lines_before = M.config.max_prefix_lines,
		max_lines_after = M.config.max_suffix_lines,
	})

	local prompt = fim.format_prompt(prefix, suffix)

	client.request_completion(prompt, M.config.payload, M.config.client, function(completion, err, raw_stdout)
		local stdout_tag = string.format("[%s] ", raw_stdout)
		if err or not completion or completion == "" then
			if M.config.debug.enabled then
				logger.record(prompt, "ERROR: " .. tostring(err), stdout_tag, M.config.debug.log_file)
			end
			return
		end

		-- Record Debug trace
		if M.config.debug.enabled then
			logger.record(prompt, "INFO: " .. tostring(completion), stdout_tag, M.config.debug.log_file)
		end

		-- Guard: verify user is still in insert mode at identical position
		local current_mode = vim.api.nvim_get_mode().mode
		if current_mode ~= "i" and current_mode ~= "ic" and current_mode ~= "ix" then
			return
		end

		local current_bufnr = vim.api.nvim_get_current_buf()
		local current_cursor = vim.api.nvim_win_get_cursor(0)
		if current_bufnr ~= bufnr or current_cursor[1] ~= row or current_cursor[2] ~= col then
			return
		end

		-- ghost_text.show expects 0-indexed row (row - 1)
		ghost_text.show(bufnr, row - 1, col, completion)
	end)
end

function M.setup(user_opts)
	-- Deep merge user options over defaults
	M.config = vim.tbl_deep_extend("force", M.defaults, user_opts or {})

	-- Initialize LibUV debounce timer once
	if not timer then
		timer = vim.uv.new_timer()
	end

	-- Clear previous autocmds if setup() is called multiple times
	vim.api.nvim_clear_autocmds({ group = augroup })

	-- Debounced trigger on typing in insert mode
	vim.api.nvim_create_autocmd("TextChangedI", {
		group = augroup,
		callback = function(args)
			if not is_enabled then
				return
			end

			-- Guard: Ignore search inputs, prompts, terminals, and external files
			if not buff.is_valid_project_buffer(args.buf) then
				return
			end

			-- Wipe current suggestion immediately when typing resumes
			ghost_text.clear()

			-- Restart debounce timer
			timer:stop()
			timer:start(
				M.config.debounce_ms,
				0,
				vim.schedule_wrap(function()
					M.trigger()
				end)
			)
		end,
	})

	-- Clear ghost text and cancel running requests on cursor move or leaving insert mode
	vim.api.nvim_create_autocmd({ "CursorMovedI", "InsertLeave" }, {
		group = augroup,
		callback = function()
			M.dismiss()
		end,
	})

	-- Expose user commands
	vim.api.nvim_create_user_command("DumboToggle", M.toggle, { desc = "Toggle Dumbo code completion" })
	vim.api.nvim_create_user_command("DumboDismiss", M.dismiss, { desc = "Dismiss active Dumbo ghost text" })
	vim.api.nvim_create_user_command("DumboInspect", function()
		logger.view_last()
	end, { desc = "Inspect last debug log" })
end

return M
