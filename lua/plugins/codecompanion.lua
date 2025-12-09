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
local OPENROUTER_CFG = cc.openrouter or {}
local OPENROUTER_API_KEY = OPENROUTER_CFG.api_key or os.getenv("OPENROUTER_API_KEY")
local OPENROUTER_MODEL = OPENROUTER_CFG.model or "qwen/qwen3-coder:free"
local OPENROUTER_ENDPOINT = OPENROUTER_CFG.endpoint or os.getenv("OPENROUTER_ENDPOINT") or "https://openrouter.ai/api"
local OPENROUTER_HEADERS = OPENROUTER_CFG.headers or {
  ["HTTP-Referer"] = "https://github.com/t-pot/gemini.nvim",
  ["X-Title"] = "Neovim CodeCompanion",
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
    log_level = "debug",
    ignore_warnings = true,
    adapters = {
      http = {
        -- OpenRouter (uses OpenAI-compatible API)
        openrouter = function()
          return require("codecompanion.adapters").extend("openai_compatible", {
            schema = {
              model = { default = OPENROUTER_MODEL },
            },
            env = {
              api_key = OPENROUTER_API_KEY,
              url = OPENROUTER_ENDPOINT,
              chat_url = "/chat/completions", -- if endpoint already includes /v1
              models_endpoint = "/models",
            },
            headers = OPENROUTER_HEADERS,
          })
        end,
        -- Local Ollama (ensure `ollama serve` is running)
        ollama = function()
          return require("codecompanion.adapters").extend("ollama", {
            schema = {
              model = { default = OLLAMA_MODEL },
            },
            endpoint = OLLAMA_ENDPOINT,
          })
        end,
      },
      cmd = {
        -- OpenRouter (uses OpenAI-compatible API)
        openrouter = function()
          return require("codecompanion.adapters").extend("openai_compatible", {
            schema = {
              model = { default = OPENROUTER_MODEL },
            },
            env = {
              api_key = OPENROUTER_API_KEY,
              url = OPENROUTER_ENDPOINT,
              chat_url = "/chat/completions",
              models_endpoint = "/models",
            },
            headers = OPENROUTER_HEADERS,
          })
        end,
        ollama = function()
          return require("codecompanion.adapters").extend("ollama", {
            schema = {
              model = { default = OLLAMA_MODEL },
            },
            endpoint = OLLAMA_ENDPOINT,
          })
        end,
      },
    },
    strategies = STRATEGIES_CFG,
  },
}
