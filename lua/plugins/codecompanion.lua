-- Load secrets safely (file is git-ignored)
local ok, secrets = pcall(require, "secrets")

-- Centralize local, git-ignored config for models/keys/endpoints
local cc = ok and (secrets.codecompanion or {}) or {}

-- Strategies config
local STRATEGIES_CFG = cc.strategies or {}

-- Ollama local config
local OLLAMA_CFG = cc.ollama or {}
local OLLAMA_MODEL = OLLAMA_CFG.model or os.getenv("OLLAMA_MODEL") or "qwen3-coder:30b"
local OLLAMA_ENDPOINT = OLLAMA_CFG.endpoint or os.getenv("OLLAMA_ENDPOINT") or "http://127.0.0.1:11434"

-- OpenRouter local config
local OR_CFG = cc.openrouter or {}
local OPENROUTER_API_KEY = OR_CFG.api_key or os.getenv("OPENROUTER_API_KEY")
local OPENROUTER_MODEL = OR_CFG.model or os.getenv("OPENROUTER_MODEL") or "qwen/qwen3-coder:free"
local OPENROUTER_ENDPOINT = OR_CFG.endpoint or os.getenv("OPENROUTER_ENDPOINT") or "https://openrouter.ai/api/v1"
local OPENROUTER_HEADERS = OR_CFG.headers or {
  ["HTTP-Referer"] = os.getenv("OPENROUTER_SITE_URL") or "https://github.com/olimorris/codecompanion.nvim",
  ["X-Title"] = os.getenv("OPENROUTER_APP_NAME") or "Neovim CodeCompanion",
}

return {
  "olimorris/codecompanion.nvim",
  version = "^18.0.0", -- upgrade to v18 API
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-telescope/telescope.nvim",
    "nvim-tree/nvim-web-devicons",
  },
  opts = {
    ignore_warnings = true,
    adapters = {
      http = {
        -- Local Ollama (ensure `ollama serve` is running)
        ollama = function()
          return require("codecompanion.adapters").extend("ollama", {
            schema = {
              model = { default = OLLAMA_MODEL },
            },
            endpoint = OLLAMA_ENDPOINT,
          })
        end,

        -- OpenRouter via OpenAI-compatible API
        openrouter = function()
          return require("codecompanion.adapters").extend("openai", {
            env = {
              -- Reads from `lua/secrets.lua` (git-ignored) or env var
              api_key = OPENROUTER_API_KEY,
            },
            schema = {
              -- Pick any OpenRouter model ID here
              -- e.g. "anthropic/claude-3.5-sonnet", "openai/gpt-4o-mini", etc.
              model = { default = OPENROUTER_MODEL },
            },
            endpoint = OPENROUTER_ENDPOINT,
            headers = OPENROUTER_HEADERS,
          })
        end,
      },
      cmd = {
        ollama = function()
          return require("codecompanion.adapters").extend("ollama", {
            schema = {
              model = { default = OLLAMA_MODEL },
            },
            endpoint = OLLAMA_ENDPOINT,
          })
        end,
        openrouter = function()
          return require("codecompanion.adapters").extend("openai", {
            env = {
              api_key = OPENROUTER_API_KEY,
            },
            schema = {
              model = { default = OPENROUTER_MODEL },
            },
            endpoint = OPENROUTER_ENDPOINT,
            headers = OPENROUTER_HEADERS,
          })
        end,
      },
    },
    strategies = STRATEGIES_CFG,
  },
}
