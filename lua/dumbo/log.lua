local M = {}

local last_entry = nil

---Appends a formatted block to the log file and stores the latest entry in memory.
---@param prompt string The exact prompt string sent to vLLM
---@param parsed_response string|nil The parsed completion received
---@param raw_response string The parsed completion received
---@param log_file string Path to the log file
function M.record(prompt, parsed_response, raw_response, log_file)
	local timestamp = os.date("%Y-%m-%d %H:%M:%S")

	last_entry = {
		timestamp = timestamp,
		prompt = prompt,
		response = parsed_response or "<nil>",
	}

	local entry_text = string.format(
		table.concat({
			"==================================================",
			"[%s] DUMBO FIM INVOCATION",
			"------------------ PROMPT SENT -------------------",
			"%s",
			"----------------- PARSED RESULT ------------------",
			"%s",
			"----------------- MODEL RAW RESPONSE ------------------",
			"%s",
			"==================================================\n\n",
		}, "\n"),
		timestamp,
		prompt,
		parsed_response or "<none>",
		raw_response
	)

	-- Non-blocking append to log file
	vim.uv.fs_open(log_file, "a", 438, function(err, fd)
		if err or not fd then
			return
		end
		vim.uv.fs_write(fd, entry_text, nil, function()
			vim.uv.fs_close(fd, function() end)
		end)
	end)
end

---Returns the most recent invocation data.
function M.get_last()
	return last_entry
end

---Opens a floating window showing the exact prompt and response of the last run.
function M.view_last()
	if not last_entry then
		vim.notify(
			"Dumbo: No completions logged yet. Ensure you have configured 'debug.enabled = true'",
			vim.log.levels.WARN
		)
		return
	end

	local lines = {
		string.format("# Dumbo Debug Inspection (%s)", last_entry.timestamp),
		"",
		"## 1. Exact Prompt Sent to Model:",
		"```",
	}

	for line in last_entry.prompt:gmatch("([^\r\n]*)") do
		table.insert(lines, line)
	end
	table.insert(lines, "```")
	table.insert(lines, "")
	table.insert(lines, "## 2. Parsed Model Completion:")
	table.insert(lines, "```")
	for line in (last_entry.response):gmatch("([^\r\n]*)") do
		table.insert(lines, line)
	end
	table.insert(lines, "```")

	-- Create scratch buffer
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].buftype = "nofile"

	-- Center floating window
	local width = math.min(100, vim.o.columns - 4)
	local height = math.min(30, vim.o.lines - 4)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = " Dumbo Prompt Inspector ",
		title_pos = "center",
	})

	-- Close on <Esc> or 'q'
	local map_opts = { buffer = buf, silent = true, nowait = true }
	vim.keymap.set("n", "q", "<cmd>close<CR>", map_opts)
	vim.keymap.set("n", "<Esc>", "<cmd>close<CR>", map_opts)
end

return M
