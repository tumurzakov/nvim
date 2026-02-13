-- This file contains your secret keys and local configuration.
-- It is ignored by git (see .gitignore).

local M = {}

-- CodeCompanion-local, git-ignored config
M.codecompanion = {
  -- ACP adapters (Codex/Gemini/Claude local CLIs)
  acp = {
    codex = {
      auth_method = "chatgpt", -- "openai-api-key"|"codex-api-key"|"chatgpt"
      -- command = "/opt/homebrew/bin/codex-acp", -- optional binary override
      -- model = "gpt-5-codex",
      -- api_key = "cmd:op read op://vault/codex/api_key --no-newline", -- CODEX_API_KEY
      -- openai_api_key = "cmd:op read op://vault/openai/api_key --no-newline", -- OPENAI_API_KEY
    },
    gemini_cli = {
      auth_method = "gemini-api-key", -- "oauth-personal"|"gemini-api-key"|"vertex-ai"
      -- command = "/opt/homebrew/bin/gemini", -- optional binary override
      -- model = "gemini-2.5-pro",
      -- api_key = "cmd:op read op://vault/gemini/api_key --no-newline", -- GEMINI_API_KEY
    },
    claude_code = {
      -- model = "claude-sonnet-4-20250514",
      -- api_key = "cmd:op read op://vault/anthropic/api_key --no-newline", -- ANTHROPIC_API_KEY
    },
  },

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
  -- ACP-first defaults
  strategies = {
    cmd = { adapter = "codex" },
    chat = { adapter = "codex" },
    inline = { adapter = "codex" },
  },
}

return M
