Neovim config (CodeCompanion tweaks)
-----------------------------------

- Adapter config lives in `lua/plugins/codecompanion.lua`.
  - OpenRouter adapter via `openai_compatible`; env defaults pulled from `secrets.lua`.
  - Ollama adapter uses `env.url` and model defaults from `secrets.lua` or env vars.
  - Chat window positioned on the right (`display.chat.window.position = "right"`).
  - Alias user command `:CC` forwards to `:CodeCompanion` with support for ranges and args.
- Keymaps in `lua/config/keymaps.lua`.
  - `<C-l>` opens/toggles chat; if visual selection is active it is sent as initial user message.
  - `<leader>cc` and `<leader>ca` keep original chat/actions bindings.
- Secrets are stored in `lua/secrets.lua` (git-ignored).

Update this file when changing adapters, keymaps, or defaults.

