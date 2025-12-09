-- This file contains your secret keys and local configuration.
-- It is ignored by git (see .gitignore).

local M = {}

-- CodeCompanion-local, git-ignored config
M.codecompanion = {
  -- OpenRouter settings
  openrouter = {
    -- IMPORTANT: Fill in your OpenRouter API key below
    api_key = "", -- or set env `OPENROUTER_API_KEY`
    model = "qwen/qwen3-coder:free", -- any OpenRouter model ID
    endpoint = "https://openrouter.ai/api/v1",
    -- Optional headers; defaults applied if omitted
    -- headers = {
    --   ["HTTP-Referer"] = "https://your.site/",
    --   ["X-Title"] = "Neovim CodeCompanion",
    -- },
  },

  -- Local Ollama settings
  -- Run `ollama serve` and ensure endpoint is reachable.
  ollama = {
    model = "qwen3-coder:30b", -- e.g. "llama3.1:8b", "qwen2.5-coder:7b", etc.
    endpoint = "http://127.0.0.1:11434",
  },

  -- Default strategies
  -- Set the adapter to "openrouter" to use OpenRouter by default
  strategies = {
    cmd = { adapter = "openrouter" },
    chat = { adapter = "openrouter" },
    inline = { adapter = "openrouter" },
  },
}

return M