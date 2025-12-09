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
              model = { default = "qwen3-coder:30b" },
            },
            endpoint = "http://127.0.0.1:11434",
          })
        end,
      },
      cmd = {
        ollama = function()
          return require("codecompanion.adapters").extend("ollama", {
            schema = {
              model = { default = "qwen3-coder:30b" },
            },
            endpoint = "http://127.0.0.1:11434",
          })
        end,
      },
    },
    strategies = {
      cmd = { adapter = "ollama" },
      chat = { adapter = "ollama" },
      inline = { adapter = "ollama" },
    },
  },
}
