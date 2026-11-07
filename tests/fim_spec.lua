local fim = require("dumbo.fim")
local client = require("dumbo.client")
local ghost_text = require("dumbo.ghost_text")

describe("fim.format_prompt", function()
	describe("Qwen (default)", function()
		it("formats standard prefix and suffix in PSM order", function()
			local prefix = "def greet(name: str):\n    "
			local suffix = "\n\ngreet('world')"

			local SUT = fim.format_prompt(prefix, suffix)
			local expected = "<|fim_prefix|>def greet(name: str):\n    <|fim_suffix|>\n\ngreet('world')<|fim_middle|>"
			assert.are.same(expected, SUT)
		end)
	end)
end)

describe("fim.extract_context", function()
	local bufnr

	before_each(function()
		bufnr = vim.api.nvim_create_buf(false, true)
	end)

	after_each(function()
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end
	end)

	it("extracts context from the middle of a line", function()
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
			"line 1",
			"prefix_middle_suffix",
			"line 3",
		})

		-- Cursor at row 2, right after 'prefix_' (col 7)
		local SUT_prefix, SUT_suffix = fim.extract_context(bufnr, 2, 7)

		assert.are.same("line 1\nprefix_", SUT_prefix)
		assert.are.same("middle_suffix\nline 3", SUT_suffix)
	end)

	it("handles cursor at start of first line (0, 0)", function()
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
			"hello world",
			"second line",
		})

		local prefix, suffix = fim.extract_context(bufnr, 1, 0)

		assert.are.same("", prefix)
		assert.are.same("hello world\nsecond line", suffix)
	end)

	it("respects max_lines_before boundary limit", function()
		local lines = {}
		for i = 1, 10 do
			table.insert(lines, "line " .. i)
		end
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

		-- Cursor on line 10, ask for max 2 lines before
		local prefix, _ = fim.extract_context(bufnr, 10, 0, { max_lines_before = 2 })

		-- Should only grab line 8 and 9 plus the empty column on line 10
		assert.are.same("line 8\nline 9\n", prefix)
	end)
end)

describe("fim.build_payload", function()
	it("constructs payload with default settings when opts is nil", function()
		local prompt = "<|fim_prefix|>def foo():<|fim_suffix|><|fim_middle|>"
		local payload = fim.build_payload(prompt)

		local expected = vim.tbl_deep_extend("force", fim.DEFAULT_PAYLOAD, {
			prompt = prompt,
		})

		assert.are.same(expected, payload)
	end)

	it("constructs payload with default settings when opts is empty table", function()
		local prompt = "<|fim_prefix|>x = <|fim_suffix|><|fim_middle|>"
		local payload = fim.build_payload(prompt, {})

		local expected = vim.tbl_deep_extend("force", fim.DEFAULT_PAYLOAD, {
			prompt = prompt,
		})

		assert.are.same(expected, payload)
	end)

	it("overrides specific fields without dropping other defaults", function()
		local prompt = "<|fim_prefix|>let a = <|fim_suffix|><|fim_middle|>"
		local payload = fim.build_payload(prompt, {
			max_tokens = 64,
			temperature = 0.2,
		})

		assert.are.same(64, payload.max_tokens)
		assert.are.same(0.2, payload.temperature)
		-- Other defaults remain intact
		assert.are.same("Qwen/Qwen2.5-Coder-7B-Instruct-AWQ", payload.model)
		assert.are.same("<|fim_middle|>", payload.stop[1])
	end)

	it("allows overriding stop tokens array completely", function()
		local prompt = "<|fim_prefix|>test<|fim_suffix|><|fim_middle|>"
		local custom_stop = { "<|fim_middle|>", "<|endoftext|>" }

		local payload = fim.build_payload(prompt, { stop = custom_stop })

		assert.are.same(custom_stop, payload.stop)
		assert.are.same(2, #payload.stop)
	end)

	it("does not mutate M.DEFAULT_PAYLOAD across calls", function()
		local initial_max_tokens = fim.DEFAULT_PAYLOAD.max_tokens

		local _ = fim.build_payload("prompt", { max_tokens = 512, model = "custom-model" })

		-- Verify internal defaults table remains untouched
		assert.are.same(initial_max_tokens, fim.DEFAULT_PAYLOAD.max_tokens)
		assert.are.same("Qwen/Qwen2.5-Coder-7B-Instruct-AWQ", fim.DEFAULT_PAYLOAD.model)
	end)
end)

describe("fim.parse_response", function()
	describe("successful completions", function()
		it("extracts clean single-line completion from standard choice", function()
			local raw = [[{
        "choices": [
          {"text": "models.CharField(max_length=50)"}
        ]
      }]]

			local completion, err = fim.parse_response(raw)

			assert.is_nil(err)
			assert.are.same("models.CharField(max_length=50)", completion)
		end)

		it("takes only the first line when model generates multiple lines", function()
			local raw = [[{
        "choices": [
          {"text": "return x + y\n    def helper():\n        pass"}
        ]
      }]]

			local completion, err = fim.parse_response(raw)

			assert.is_nil(err)
			assert.are.same("return x + y", completion)
		end)

		it("skips an empty leading newline and returns the first content line", function()
			local raw = [[{
        "choices": [
          {"text": "\n    print('hello world')"}
        ]
      }]]

			local completion, err = fim.parse_response(raw)

			assert.is_nil(err)
			assert.are.same("    print('hello world')", completion)
		end)

		it("strips carriage returns on CRLF line endings", function()
			local raw = [[{
        "choices": [
          {"text": "response = client.get()\r\n    return response"}
        ]
      }]]

			local completion, err = fim.parse_response(raw)

			assert.is_nil(err)
			assert.are.same("response = client.get()", completion)
		end)

		it("returns nil completion and nil error when choice text is entirely empty", function()
			local raw = [[{
        "choices": [
          {"text": ""}
        ]
      }]]

			local completion, err = fim.parse_response(raw)

			assert.is_nil(completion)
			assert.is_nil(err)
		end)
	end)

	describe("error handling", function()
		it("returns error on nil or empty input string", function()
			local completion1, err1 = fim.parse_response(nil)
			assert.is_nil(completion1)
			assert.are.same("empty response", err1)

			local completion2, err2 = fim.parse_response("")
			assert.is_nil(completion2)
			assert.are.same("empty response", err2)
		end)

		it("returns error on malformed JSON payload", function()
			local completion, err = fim.parse_response("502 Bad Gateway: upstream server down")

			assert.is_nil(completion)
			assert.are.same("invalid json", err)
		end)

		it("extracts error message from API error response table", function()
			local raw = [[{
        "error": {
          "message": "Model 'Qwen/Qwen2.5-Coder-7B-Instruct-AWQ' not found",
          "type": "invalid_request_error"
        }
      }]]

			local completion, err = fim.parse_response(raw)

			assert.is_nil(completion)
			assert.are.same("Model 'Qwen/Qwen2.5-Coder-7B-Instruct-AWQ' not found", err)
		end)

		it("returns error when choices array is empty", function()
			local raw = [[{ "choices": [] }]]

			local completion, err = fim.parse_response(raw)

			assert.is_nil(completion)
			assert.are.same("no choices returned", err)
		end)
	end)
end)

describe("client module", function()
	after_each(function()
		client.cancel()
	end)

	describe("configuration and command building", function()
		it("exposes default configuration", function()
			assert.is_nil(client.DEFAULT_CONFIG.endpoint)
			assert.are.same(5000, client.DEFAULT_CONFIG.timeout_ms)
			assert.is_nil(client.DEFAULT_CONFIG.api_key)
		end)

		it("builds standard curl command without auth header", function()
			local cmd = client.build_curl_cmd("http://127.0.0.1:8000/v1/completions", '{"prompt":"x"}', 3000, nil)

			assert.are.same("curl", cmd[1])
			assert.are.same("-s", cmd[2])
			assert.are.same("-X", cmd[3])
			assert.are.same("POST", cmd[4])
			assert.are.same("-H", cmd[5])
			assert.are.same("Content-Type: application/json", cmd[6])
			assert.are.same("-m", cmd[7])
			assert.are.same("3", cmd[8])
			assert.are.same("--data-binary", cmd[9])
			assert.are.same('{"prompt":"x"}', cmd[10])
			assert.are.same("http://127.0.0.1:8000/v1/completions", cmd[11])
		end)

		it("injects Authorization header when api_key is provided", function()
			local cmd = client.build_curl_cmd("http://remote:8000/v1/completions", "{}", 5000, "secret-token")

			local has_auth = false
			for i, arg in ipairs(cmd) do
				if arg == "-H" and cmd[i + 1] == "Authorization: Bearer secret-token" then
					has_auth = true
					break
				end
			end

			assert.is_true(has_auth)
		end)
	end)

	describe("cancellation", function()
		it("allows calling cancel safely when no job is active", function()
			assert.has_no.errors(function()
				client.cancel()
			end)
		end)
	end)
end)

describe("ghost_text.show", function()
	local bufnr

	before_each(function()
		bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "def foo():", "" })
	end)

	after_each(function()
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end
	end)

	it("renders inline ghost text and caches suggestion state", function()
		local mark_id = ghost_text.show(bufnr, 0, 10, " pass")

		assert.is_not_nil(mark_id)

		local state = ghost_text.get_current()
		assert.is_not_nil(state)
		assert.are.same(bufnr, state.bufnr)
		assert.are.same(0, state.row)
		assert.are.same(10, state.col)
		assert.are.same(" pass", state.text)
		assert.are.same(mark_id, state.extmark_id)
	end)

	it("returns nil and does not set state when text is empty", function()
		local mark_id = ghost_text.show(bufnr, 0, 10, "")

		assert.is_nil(mark_id)
		assert.is_nil(ghost_text.get_current())
	end)

	it("replaces previous extmark when called consecutively", function()
		local first_id = ghost_text.show(bufnr, 0, 10, " first")
		local second_id = ghost_text.show(bufnr, 0, 10, " second")

		assert.are_not.same(first_id, second_id)

		local state = ghost_text.get_current()
		assert.are.same(" second", state.text)
		assert.are.same(second_id, state.extmark_id)
	end)
end)

describe("ghost_text.clear", function()
	local bufnr

	before_each(function()
		bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "def foo():", "" })
	end)

	after_each(function()
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end
	end)

	it("can be called safely when no suggestion exists", function()
		assert.has_no.errors(function()
			ghost_text.clear()
		end)
		assert.is_nil(ghost_text.get_current())
	end)

	it("removes active extmark and clears cached suggestion state", function()
		local mark_id = ghost_text.show(bufnr, 0, 10, " pass")
		assert.is_not_nil(mark_id)
		assert.is_not_nil(ghost_text.get_current())

		ghost_text.clear()

		assert.is_nil(ghost_text.get_current())

		-- Verify the extmark was actually removed from the buffer
		-- nvim_buf_get_extmark_by_id returns an empty table {} if not found
		local mark =
			vim.api.nvim_buf_get_extmark_by_id(bufnr, vim.api.nvim_create_namespace("dumbo_ghost_text"), mark_id, {})
		assert.are.same({}, mark)
	end)

	it("handles case where buffer was already deleted before clear()", function()
		ghost_text.show(bufnr, 0, 10, " pass")

		-- Force-wipe buffer out from under the module
		vim.api.nvim_buf_delete(bufnr, { force = true })

		assert.has_no.errors(function()
			ghost_text.clear()
		end)
		assert.is_nil(ghost_text.get_current())
	end)
end)

describe("ghost_text.accept", function()
	local bufnr

	before_each(function()
		bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "def calculate():" })
	end)

	after_each(function()
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end
	end)

	it("returns false when no suggestion is active", function()
		local accepted = ghost_text.accept()

		assert.is_false(accepted)
	end)

	it("inserts suggestion text into the buffer and clears state", function()
		-- Render suggestion after "def calculate(" at row 0, col 14
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "def calculate()" })
		ghost_text.show(bufnr, 0, 14, "x, y")

		local accepted = ghost_text.accept()

		assert.is_true(accepted)
		assert.is_nil(ghost_text.get_current())

		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		assert.are.same("def calculate(x, y)", lines[1])
	end)

	it("preserves suffix text to the right of the insertion point", function()
		-- Cursor is between parentheses: "foo(|)" -> row 0, col 4
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "foo()" })
		ghost_text.show(bufnr, 0, 4, "bar")

		local accepted = ghost_text.accept()

		assert.is_true(accepted)
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		assert.are.same("foo(bar)", lines[1])
	end)

	it("moves window cursor to the end of inserted text", function()
		-- Attach buffer to current window for cursor testing
		vim.api.nvim_set_current_buf(bufnr)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "let x = " })
		vim.api.nvim_win_set_cursor(0, { 1, 8 })

		ghost_text.show(bufnr, 0, 8, "100 + y")
		local accepted = ghost_text.accept()

		assert.is_true(accepted)

		local cursor = vim.api.nvim_win_get_cursor(0)
		-- Row is 1-indexed (1), col is 8 + 7 = 15
		assert.are.same({ 1, 14 }, cursor)
	end)

	it("moves window cursor to the end of inserted text", function()
		vim.api.nvim_set_current_buf(bufnr)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "let x = ;" })
		vim.api.nvim_win_set_cursor(0, { 1, 8 })

		ghost_text.show(bufnr, 0, 8, "100 + y")
		local accepted = ghost_text.accept()

		assert.is_true(accepted)

		local cursor = vim.api.nvim_win_get_cursor(0)
		assert.are.same({ 1, 15 }, cursor)
	end)
end)
