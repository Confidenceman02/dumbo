local fim = require("dumbo.fim")

local M = {}

---@class DumboClientConfig
---@field endpoint? string Full URL to completions endpoint (default: "http://127.0.0.1:8000/v1/completions")
---@field api_key? string Optional Bearer token for remote/protected proxies
---@field timeout_ms? integer Request timeout in milliseconds (default: 5000)

---@type DumboClientConfig
M.DEFAULT_CONFIG = {
	endpoint = nil,
	api_key = nil,
	timeout_ms = 5000,
}

---Tracks currently active sub-process to allow cancellation of stale requests.
---@type vim.SystemObj|nil
local active_job = nil

---Cancels any currently running completion request.
function M.cancel()
	if active_job and not active_job:is_closing() then
		active_job:kill(9)
		active_job = nil
	end
end

---Builds the curl CLI arguments array for vim.system.
---Exposed to allow deterministic unit testing of flag construction.
---@param endpoint string
---@param body string
---@param timeout_ms integer
---@param api_key? string
---@return string[]
function M.build_curl_cmd(endpoint, body, timeout_ms, api_key)
	local timeout_sec = tostring(math.max(1, math.floor(timeout_ms / 1000)))

	local cmd = {
		"curl",
		"-s",
		"-X",
		"POST",
		"-H",
		"Content-Type: application/json",
		"-m",
		timeout_sec,
		"--data-binary",
		body,
		endpoint .. "/completions",
	}

	if api_key and api_key ~= "" then
		table.insert(cmd, 6, "-H")
		table.insert(cmd, 7, "Authorization: Bearer " .. api_key)
	end

	return cmd
end

---Sends an asynchronous completion request to the vLLM endpoint.
---@param prompt string The formatted FIM prompt string
---@param opts? DumboDefaultPayload Optional inference payload overrides
---@param client_config? DumboClientConfig Endpoint and network configuration
---@param callback fun(completion: string|nil, err: string|nil, raw_stdout: string) Callback invoked on Neovim's main loop
function M.request_completion(prompt, opts, client_config, callback)
	-- Cancel previous in-flight request to prevent race conditions on rapid typing
	M.cancel()

	local cfg = vim.tbl_deep_extend("force", M.DEFAULT_CONFIG, client_config or {})
	local payload = fim.build_payload(prompt, opts)
	local body = vim.json.encode(payload)
	local cmd = M.build_curl_cmd(cfg.endpoint, body, cfg.timeout_ms, cfg.api_key)

	active_job = vim.system(cmd, { text = true }, function(obj)
		active_job = nil

		-- Bounce execution back onto Neovim's main event loop
		vim.schedule(function()
			if obj.code ~= 0 then
				-- Exit code 137 (128 + 9) or 9 indicates process was explicitly killed by M.cancel()
				if obj.code == 137 or obj.code == 9 then
					return
				end
				return callback(
					nil,
					"curl failed (code " .. tostring(obj.code) .. "): " .. (obj.stderr or ""),
					obj.stdout
				)
			end

			local completion, err = fim.parse_response(obj.stdout)
			callback(completion, err, obj.stdout)
		end)
	end)
end

return M
