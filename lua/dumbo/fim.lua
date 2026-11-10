local M = {}

---@class DumboDefaultPayload
---@field model? string The model name/identifier hosted on vLLM.
---@field max_tokens? integer Maximum number of completion tokens to generate.
---@field temperature? number Sampling temperature (0.0 for greedy decoding).
---@field stop? string[] Array of stop sequence strings or tokens.

M.PATTERNS = {
	qwen = {
		prefix = "<|fim_prefix|>",
		suffix = "<|fim_suffix|>",
		middle = "<|fim_middle|>",
		format = function(p, s, tok)
			return tok.prefix .. p .. tok.suffix .. s .. tok.middle
		end,
	},
}

M.DEFAULT_PAYLOAD = {
	model = "Qwen/Qwen2.5-Coder-7B-Instruct-AWQ",
	max_tokens = 64,
	temperature = 0.2,
	stop = {
		"<|fim_middle|>",
		"<|fim_suffix|>",
		"<|endoftext|>",
		"\n\n",
	},
}

--Formats prefix and suffix into model-specific FIM prompt tokens.
---@param prefix? string Text before cursor
---@param suffix? string Text after cursor
---@param model_type? string "qwen" (default)
---@return string
function M.format_prompt(prefix, suffix, model_type)
	local pattern = M.PATTERNS[model_type or "qwen"]

	if not pattern then
		error(string.format("Unknown model type: %s", tostring(model_type)))
	end

	prefix = prefix or ""
	suffix = suffix or ""

	return pattern.format(prefix, suffix, pattern)
end

---Extracts prefix and suffix text around a cursor position in a given buffer.
---@param bufnr number Buffer handle (0 for current)
---@param row number 1-indexed row
---@param col number 0-indexed byte column
---@param opts? { max_lines_before?: number, max_lines_after?: number }
---@return string prefix, string suffix
function M.extract_context(bufnr, row, col, opts)
	opts = opts or {}
	local max_before = opts.max_lines_before or 50
	local max_after = opts.max_lines_after or 20

	local total_lines = vim.api.nvim_buf_line_count(bufnr)
	if total_lines == 0 then
		return "", ""
	end

	-- Clamp row to valid buffer range
	row = math.max(1, math.min(row, total_lines))

	-- 1. Lines strictly before current line
	local start_row = math.max(0, row - 1 - max_before)
	local lines_before = vim.api.nvim_buf_get_lines(bufnr, start_row, row - 1, false)

	-- 2. Current line split at cursor col
	local current_line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
	local line_prefix = string.sub(current_line, 1, col)
	local line_suffix = string.sub(current_line, col + 1)

	table.insert(lines_before, line_prefix)
	local prefix = table.concat(lines_before, "\n")

	-- 3. Lines strictly after current line
	local end_row = math.min(total_lines, row + max_after)
	local lines_after = vim.api.nvim_buf_get_lines(bufnr, row, end_row, false)

	local suffix_lines = { line_suffix }
	for _, line in ipairs(lines_after) do
		table.insert(suffix_lines, line)
	end
	local suffix = table.concat(suffix_lines, "\n")

	return prefix, suffix
end

---Builds the JSON payload table for vLLM /v1/completions.
---@param prompt string The formatted FIM prompt
---@param opts? DumboDefaultPayload Optional overrides for inference default
---@return table
function M.build_payload(prompt, opts)
	local payload = vim.tbl_deep_extend("force", M.DEFAULT_PAYLOAD, opts or {})
	payload.prompt = prompt
	return payload
end

---Parses the raw JSON response payload from a vLLM `/v1/completions` endpoint.
---Decodes the JSON body, checks for API error fields, and extracts the first
---non-empty completion line from `choices[1].text` suitable for inline ghost text.
---@param raw_json? string The raw HTTP response body string returned by the server.
---@return string|nil completion The extracted single-line completion text, or `nil` if empty or on error.
---@return string|nil err An error description if parsing failed, or `nil` on success.
function M.parse_response(raw_json)
	if not raw_json or raw_json == "" then
		return nil, "empty response"
	end

	local ok, data = pcall(vim.json.decode, raw_json)
	if not ok or type(data) ~= "table" then
		return nil, "invalid json"
	end

	if data.error then
		return nil, data.error.message or "api error"
	end

	if not data.choices or #data.choices == 0 then
		return nil, "no choices returned"
	end

	local choice = data.choices[1]
	local text = choice.text

	if not text or text == "" then
		return nil, nil
	end

	-- Strip carriage returns (CRLF safety)
	text = text:gsub("\r", "")

	-- Isolate the immediate line continuation
	local lines = vim.split(text, "\n", { plain = true })
	local first_line = lines[1]

	-- If the model returned an empty first line with content below, take the first non-empty line
	if first_line == "" and #lines > 1 then
		first_line = lines[2]
	end

	return first_line, nil
end

return M
