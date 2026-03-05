-- Copy this file to lua/config/settings_local.lua (git-ignored)
-- and customize per machine.

local M = {}

M.codecompanion = {
  acp = {
    codex = {
      auth_method = "chatgpt", -- "openai-api-key"|"codex-api-key"|"chatgpt"
      -- command = "/opt/homebrew/bin/codex-acp",
      -- model = "gpt-5-codex",
      -- api_key = "",
      -- openai_api_key = "",
    },
    gemini_cli = {
      auth_method = "oauth-personal", -- "oauth-personal"|"gemini-api-key"|"vertex-ai"
      -- command = "/opt/homebrew/bin/gemini",
      -- model = "gemini-2.5-pro",
      -- api_key = "",
    },
    claude_code = {
      -- model = "claude-sonnet-4-20250514",
      -- api_key = "",
    },
  },

  openrouter = {
    api_key = "", -- or env OPENROUTER_API_KEY
    model = "qwen/qwen3-coder:free",
    endpoint = "https://openrouter.ai/api/v1",
  },

  ollama = {
    model = "qwen3-coder:30b",
    endpoint = "http://127.0.0.1:11434",
  },

  -- Control defaults for /ci, chat, inline, cmd.
  strategies = {
    cmd = { adapter = "codex" },
    chat = { adapter = "codex" },
    inline = { adapter = "codex" },
  },
}

M.keybindings = {}

function M.keybindings.apply(map)
  map("n", "`", "<cmd>NvimTreeToggle<CR>", { desc = "Toggle tree (local)" })
  map("n", "§", "<cmd>NvimTreeToggle<CR>", { desc = "Toggle tree (local)" })
end

return M
