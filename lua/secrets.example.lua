-- Copy this file to `lua/secrets.lua` and fill in your keys.
-- `lua/secrets.lua` is ignored by git (see .gitignore).

local M = {}

-- CodeCompanion-local, git-ignored config
-- Copy to `lua/secrets.lua` and fill with your values.
-- You can also use env vars as fallbacks (see `codecompanion.lua`).
M.codecompanion = {
  -- Local Ollama settings
  -- Run `ollama serve` and ensure endpoint is reachable.
  ollama = {
    model = "qwen3-coder:30b",      -- e.g. "llama3.1:8b", "qwen2.5-coder:7b", etc.
    endpoint = "http://127.0.0.1:11434",
  },

  -- OpenRouter settings
  openrouter = {
    api_key = "",                    -- or set env `OPENROUTER_API_KEY`
    model = "qwen/qwen3-coder:free", -- any OpenRouter model ID
    endpoint = "https://openrouter.ai/api/v1",
    -- Optional headers; defaults applied if omitted
    -- headers = {
    --   ["HTTP-Referer"] = "https://your.site/",
    --   ["X-Title"] = "Neovim CodeCompanion",
    -- },
  },
}

return M
