-- Load local settings safely (file is git-ignored)
local ok, settings_local = pcall(require, "config.settings_local")

-- Centralize local, git-ignored config for models/keys/endpoints
local cc = ok and (settings_local.codecompanion or {}) or {}

-- Interactions config (adapters per interaction type)
local INTERACTIONS_CFG = vim.tbl_deep_extend("force", {
  cmd = { adapter = "claude_code" },
  chat = { adapter = "claude_code" },
  inline = { adapter = "claude_code" },
}, cc.strategies or {})

local function compact_env(env)
  local out = {}
  for key, value in pairs(env or {}) do
    if value ~= nil and value ~= "" then
      out[key] = value
    end
  end
  return out
end

local function exepath_or(cmd)
  local resolved = vim.fn.exepath(cmd)
  if resolved ~= "" then
    return resolved
  end
  return cmd
end

-- ACP local config
local ACP_CFG = cc.acp or {}
local CODEX_CFG = ACP_CFG.codex or {}
local GEMINI_CFG = ACP_CFG.gemini_cli or {}
local CLAUDE_CFG = cc.claude_code or ACP_CFG.claude_code or {}

local CODEX_AUTH_METHOD = CODEX_CFG.auth_method or "chatgpt"
local CODEX_MODEL = CODEX_CFG.model
local CODEX_API_KEY = CODEX_CFG.api_key
local OPENAI_API_KEY = CODEX_CFG.openai_api_key
local CODEX_BIN = CODEX_CFG.command or exepath_or("codex-acp")

local GEMINI_AUTH_METHOD = GEMINI_CFG.auth_method or "oauth-personal"
local GEMINI_MODEL = GEMINI_CFG.model
local GEMINI_API_KEY = GEMINI_CFG.api_key
local GEMINI_BIN = GEMINI_CFG.command or exepath_or("gemini")

local CLAUDE_MODEL = CLAUDE_CFG.model
local CLAUDE_CODE_OAUTH_TOKEN = CLAUDE_CFG.api_key or os.getenv("CLAUDE_CODE_OAUTH_TOKEN")

-- Ollama local config
local OLLAMA_CFG = cc.ollama or {}
local OLLAMA_MODEL = OLLAMA_CFG.model or os.getenv("OLLAMA_MODEL") or "qwen3-coder:30b"
local OLLAMA_ENDPOINT = OLLAMA_CFG.endpoint or os.getenv("OLLAMA_ENDPOINT") or "http://127.0.0.1:11434"

-- OpenRouter local config
local OPENROUTER_CFG = cc.openrouter or {}
local OPENROUTER_API_KEY = OPENROUTER_CFG.api_key or os.getenv("OPENROUTER_API_KEY")
local OPENROUTER_MODEL = OPENROUTER_CFG.model or "qwen/qwen3-coder:free"
local OPENROUTER_ENDPOINT = OPENROUTER_CFG.endpoint or os.getenv("OPENROUTER_ENDPOINT") or "https://openrouter.ai/api/v1"
local OPENROUTER_HEADERS = OPENROUTER_CFG.headers or {
  ["HTTP-Referer"] = "https://github.com/t-pot/gemini.nvim",
  ["X-Title"] = "Neovim CodeCompanion",
}

-- Dial (OpenAI-compatible proxy) local config
local DIAL_CFG = cc.dial or {}
local DIAL_API_KEY = DIAL_CFG.api_key or os.getenv("DIAL_API_KEY")
local DIAL_MODEL = DIAL_CFG.model or ""
local DIAL_ENDPOINT = DIAL_CFG.endpoint or os.getenv("DIAL_ENDPOINT")

return {
  "olimorris/codecompanion.nvim",
  version = "^18.0.0", -- upgrade to v18 API
  build = "git apply --ignore-whitespace " .. vim.fn.stdpath("config") .. "/patches/codecompanion.patch",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-telescope/telescope.nvim",
    "nvim-tree/nvim-web-devicons",
  },
  opts = {
    log_level = "debug",
    ignore_warnings = true,
    interactions = vim.tbl_deep_extend("force", INTERACTIONS_CFG, {
      chat = {
        opts = {
          system_prompt = function(ctx)
            local agents_md = vim.fs.joinpath(vim.fn.stdpath("config"), "AGENTS.md")
            local global_rules = ""
            local f = io.open(agents_md, "r")
            if f then
              global_rules = f:read("*a")
              f:close()
            end

            return ctx.default_system_prompt
              .. string.format(
                [[Additional context:
All non-code text responses must be written in the %s language.
The current date is %s.
The user's Neovim version is %s.
The user is working on a %s machine. Please respond with system specific commands if applicable.
## OUTPUT WIDTH CONSTRAINT (MANDATORY)
The output window is exactly %d columns wide. This is a hard limit — every line of your response MUST fit within %d characters.
Rules:
- Before writing a markdown table, mentally calculate total width: sum of all column contents + separators (` | `). If it exceeds %d characters, DO NOT use a table.
- When a table would be too wide, use a vertical key-value format instead:
  **Row Title**
  - Key1: value1
  - Key2: value2
- Code blocks also must not exceed %d columns.
- This constraint overrides all other formatting preferences.
]],
                ctx.language,
                ctx.date,
                ctx.nvim_version,
                ctx.os,
                vim.api.nvim_win_get_width(0),
                vim.api.nvim_win_get_width(0),
                vim.api.nvim_win_get_width(0),
                vim.api.nvim_win_get_width(0)
              )
              .. "\n" .. global_rules
          end,
        },
        slash_commands = {
          ["chats"] = {
            callback = "slash_commands.chats",
            description = "Load a saved chat from .chats/",
            opts = {
              contains_code = false,
              provider = "telescope",
            },
          },
        },
        tools = {
          ["agenda"] = {
            callback = "tools.build_agenda",
            description = "Fetch all context sources (emails, Teams, web) and return raw data for building a daily agenda",
            opts = {
              require_approval_before = false,
            },
          },
          ["email_fetch"] = {
            callback = "tools.email_fetch",
            description = "Fetch emails from Mail.app for a given date",
            opts = {
              require_approval_before = false,
            },
          },
          ["teams_activity"] = {
            callback = "tools.teams_activity",
            description = "Fetch Teams activity feed",
            opts = {
              require_approval_before = false,
            },
          },
          ["teams_calendar"] = {
            callback = "tools.teams_calendar",
            description = "Fetch Teams calendar month view",
            opts = {
              require_approval_before = false,
            },
          },
          ["teams_chats"] = {
            callback = "tools.teams_chats",
            description = "Fetch recent Teams chats with messages",
            opts = {
              require_approval_before = false,
            },
          },
        },
        keymaps = {
          next_chat = {
            modes = { n = "}" },
            index = 11,
            callback = function(chat)
              require("config.codecompanion_chat_archive").next_chat.callback(chat)
            end,
            description = "[Nav] Next chat (loads saved)",
          },
          previous_chat = {
            modes = { n = "{" },
            index = 12,
            callback = function(chat)
              require("config.codecompanion_chat_archive").previous_chat.callback(chat)
            end,
            description = "[Nav] Previous chat (loads saved)",
          },
        },
      },
    }),
    extensions = {
      mcphub = {
        callback = "mcphub.extensions.codecompanion",
        opts = {
          make_vars = true,
          make_slash_commands = true,
          show_result_in_chat = true,
        },
      },
    },
    rules = {},
    display = {
      chat = {
        window = {
          position = "right", -- open chat split on the right
        },
      },
    },
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
        -- Dial / OpenAI-compatible proxy (custom adapter)
        dial = function()
          return require("codecompanion.adapters").extend(require("adapters.dial"), {
            schema = {
              model = { default = DIAL_MODEL },
            },
            env = {
              api_key = DIAL_API_KEY,
              url = DIAL_ENDPOINT,
            },
          })
        end,
        -- Local Ollama (ensure `ollama serve` is running)
        ollama = function()
          return require("codecompanion.adapters").extend("ollama", {
            schema = {
              model = { default = OLLAMA_MODEL },
              num_ctx = { default = 16384, },
            },
            env = {
              url = OLLAMA_ENDPOINT,
            },
          })
        end,
      },
      acp = {
        codex = function()
          return require("codecompanion.adapters").extend("codex", {
            commands = {
              default = { CODEX_BIN },
            },
            defaults = {
              auth_method = CODEX_AUTH_METHOD, -- "openai-api-key"|"codex-api-key"|"chatgpt"
              model = CODEX_MODEL,
            },
            env = compact_env({
              CODEX_API_KEY = CODEX_API_KEY,
              OPENAI_API_KEY = OPENAI_API_KEY,
            }),
          })
        end,
        gemini = function()
          return require("codecompanion.adapters").extend("gemini_cli", {
            commands = {
              default = { GEMINI_BIN, "--experimental-acp" },
            },
            defaults = {
              auth_method = GEMINI_AUTH_METHOD, -- "oauth-personal"|"gemini-api-key"|"vertex-ai"
              model = GEMINI_MODEL,
            },
            env = compact_env({
              GEMINI_API_KEY = GEMINI_API_KEY,
            }),
          })
        end,
        gemini_cli = function()
          return require("codecompanion.adapters").extend("gemini_cli", {
            commands = {
              default = { GEMINI_BIN, "--experimental-acp" },
            },
            defaults = {
              auth_method = GEMINI_AUTH_METHOD, -- "oauth-personal"|"gemini-api-key"|"vertex-ai"
              model = GEMINI_MODEL,
            },
            env = compact_env({
              GEMINI_API_KEY = GEMINI_API_KEY,
            }),
          })
        end,
        claude_code = function()
          return require("codecompanion.adapters").extend("claude_code", {
            commands = {
              default = { vim.fn.expand("~/.local/bin/claude-code-acp") },
              yolo = { vim.fn.expand("~/.local/bin/claude-code-acp"), "--yolo" },
            },
            defaults = {
              timeout = 120000, -- 2 minutes for slow responses
              mcpServers = {
                {
                  name = "context-tools",
                  command = "python3",
                  args = { os.getenv("HOME") .. "/sources/context/src/mcp_server.py" },
                  env = {},
                },
              },
            },
            env = compact_env({
              CLAUDE_CODE_OAUTH_TOKEN = CLAUDE_CODE_OAUTH_TOKEN,
            }),
          })
        end,
      },
    },
    -- strategies removed: merged into interactions above
  },
  config = function(_, opts)
    if opts.adapters then
      opts.adapters.http = opts.adapters.http or {}

      if opts.adapters.cmd then
        opts.adapters.http = vim.tbl_deep_extend("force", opts.adapters.http, opts.adapters.cmd)
        opts.adapters.cmd = nil
      end

      if opts.adapters.opts then
        opts.adapters.http.opts = vim.tbl_deep_extend("force", opts.adapters.http.opts or {}, opts.adapters.opts)
        opts.adapters.opts = nil
      end
    end

    require("codecompanion").setup(opts)
    require("config.codecompanion_chat_archive").setup()

    -- Alias: :CC (supports range + args) -> :CodeCompanionChat
    vim.api.nvim_create_user_command("CC", function(args)
      local range_prefix = ""
      if args.range == 2 then
        range_prefix = string.format("%d,%d", args.line1, args.line2)
      end

      local joined = table.concat(args.fargs, " ")
      if joined ~= "" then
        joined = " " .. joined
      end

      vim.cmd(string.format("%sCodeCompanion%s", range_prefix, joined))
    end, { nargs = "*", range = true, desc = "Alias for CodeCompanion" })
  end,
}
