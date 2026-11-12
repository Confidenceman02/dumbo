# dumbo

Fast, minimal, and non-blocking Fill-In-the-Middle (FIM) code completion for Neovim, powered by your local vLLM instance.

`dumbo.nvim` provides an inline ghost-text experience similar to GitHub Copilot, but runs 100% locally and privately on your machine using open-weights models like Qwen 2.5 Coder.

---

## Features

- **True Fill-In-the-Middle (FIM):** Formats prefix and suffix context using model-specific FIM tokens (`<|fim_prefix|>`, `<|fim_suffix|>`, `<|fim_middle|>`).
- **Zero Editor Lag:** Uses `vim.system` for asynchronous, non-blocking network requests without hanging Neovim's main thread.
- **Debounced Triggers:** Powered by LibUV timers (`vim.uv`) to prevent flooding your GPU while you are actively typing.
- **Fail-Fast Invalidation:** Automatically discards stale in-flight model responses if your cursor moves or buffer state changes before completion finishes.
- **Native Extmarks:** Lightweight inline ghost text rendering via `nvim_buf_set_extmark`.
- **Zero Heavy Dependencies:** Written entirely in pure Lua using Neovim core APIs.

---

## Requirements

- Neovim `>= 0.10.0`
- `curl` available in `$PATH`
- A running completion server (such as [vLLM](https://github.com/vllm-project/vllm)) serving an OpenAI-compatible `/v1/completions` endpoint.

---

## Installation & Setup

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
return {
  "Confidenceman02/dumbo",
  event = { "BufReadPre", "BufNewFile" },
  config = function()
    vim.api.nvim_set_hl(0, "DumboGhostText", { fg = "#6c7086", italic = true, default = true })

    local dumbo = require("dumbo")
    dumbo.setup({
      debounce_ms = 200,
      client = {
        endpoint = "http://10.1.1.2/v1",
        model = "Qwen/Qwen2.5-Coder-7B-Instruct-AWQ",
      },
      payload = {
        max_tokens = 48,
        temperature = 0.0,
      },
    })

    -- Map <Tab> to accept ghost text if present
    vim.keymap.set("i", "<Tab>", function()
      if not dumbo.accept() then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "n", false)
      end
    end, { silent = true, desc = "Accept Dumbo completion" })

    -- Map <C-]> to dismiss suggestion
    vim.keymap.set("i", "<C-]>", function()
      dumbo.dismiss()
    end, { silent = true, desc = "Dismiss Dumbo suggestion" })
  end,
}
```

---

## Configuration

Below are the default options passed to `dumbo.setup()`:

```lua
require("dumbo").setup({
  -- Debounce delay in milliseconds before dispatching an inference request
  debounce_ms = 150,

  -- Maximum lines of surrounding code fed to the model
  max_prefix_lines = 100,
  max_suffix_lines = 50,

  -- Network / vLLM client configuration
  client = {
    endpoint = "http://127.0.0.1:8000/v1/completions",
    model = "Qwen/Qwen2.5-Coder-7B-Instruct-AWQ",
    timeout_ms = 5000,
    api_key = nil,
  },

  -- Model inference parameters
  payload = {
    max_tokens = 32,
    temperature = 0.0,
    top_p = 1.0,
    stop = {
      "<|fim_prefix|>",
      "<|fim_suffix|>",
      "<|fim_middle|>",
    },
  },
})
```

---

## Commands & Lua API

### User Commands

- `:DumboToggle` – Toggle automatic inline suggestions on or off.
- `:DumboDismiss` – Immediately cancel running network jobs and clear visible ghost text.

### Lua API

```lua
local dumbo = require("dumbo")

dumbo.setup(opts) -- Initialize plugin, register autocommands, and merge configuration
dumbo.trigger()   -- Manually trigger a completion request at the current cursor position
dumbo.accept()    -- Accept active ghost text (returns true on success, false if none exists)
dumbo.dismiss()   -- Clear ghost text and cancel in-flight curl jobs
dumbo.toggle()    -- Toggle completion on or off
```

---

## Backend Setup (vLLM)

Example command to launch a local vLLM instance serving Qwen with FIM support:

```bash
vllm serve Qwen/Qwen2.5-Coder-7B-Instruct-AWQ \
  --port 8000 \
  --host 127.0.0.1 \
  --max-model-len 4096 \
  --gpu-memory-utilization 0.90
```

Verify your server is responding before starting Neovim:

```bash
curl -s http://127.0.0.1:8000/v1/models | jq .data[0].id
```

---

## Testing

```bash
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests { minimal_init = 'tests/minimal_init.lua' }"
```

## License

MIT
