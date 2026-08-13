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

  -- OpenAI-compatible proxy (e.g. corporate AI gateway).
  -- Leave commented out unless you have access.
  -- dial = {
  --   api_key = "",
  --   model = "gpt-4o-2024-08-06",
  --   endpoint = "https://your-proxy.example.com/openai",
  -- },

  -- Control defaults for /ci, chat, inline, cmd.
  strategies = {
    cmd = { adapter = "codex" },
    chat = { adapter = "codex" },
    inline = { adapter = "codex" },
  },
}

-- AI checker backend for the gR review view's default "ai" checker (see the
-- "If omitted..." note below). Selects which command runs the diff review.
-- M.diff_review = {
--   claude_command = "/usr/local/bin/claude",   -- defaults to `claude` on PATH
--   model          = "claude-haiku-4-5-20251001",
--   env            = { ... },                    -- extra env for the command
--
--   -- Switch to local Ollama:
--   -- claude_command = vim.fn.expand("~/.config/nvim/scripts/ollama-agent"),
--   -- env = { OLLAMA_MODEL = "qwen3-coder:30b" },
-- }
-- Any backend: write a script that reads stdin and streams to stdout;
-- point claude_command at it. The -p flag is passed and can be ignored.

-- Base branch used by nvim-tree `gR` (review vs base). Defaults to "main".
-- M.git_base_branch = "develop"

-- Git remote used for fetch/push in gR (P), ReviewMR, and the gB branch
-- switcher. Defaults to "origin".
-- M.git_remote = "origin"

-- Where `gS` (save a graded MR/branch review) writes its markdown, under a
-- per-ticket subfolder: <tasks_dir>/<TICKET>/review-<repo>-mr<iid>.md (or
-- review-<repo>-<ticket>.md for a non-MR review). Defaults to ~/sources/nbs-art/tasks.
-- Also where the Jira ticket mirror (<TICKET>/ticket.md) is written.
-- M.tasks_dir = "~/sources/nbs-art/tasks"

-- Jira ticket integration for the review view. OFF by default — the whole
-- feature (gR sidebar ticket node + tasks/<TICKET>/ticket.md mirror, the gJ
-- hotkey, gS review enrichment, and the :ReviewMR GitLab branch lookup) is gated
-- by `enabled` and makes NO external calls unless you turn it on. Leave it off in
-- environments without Jira (e.g. Novartis).
--   enabled  master trigger — must be true for any of the above to run
--   token    Jira PAT (Bearer); falls back to $JIRA_API_TOKEN, then the
--            epam-jira MCP server's env in ~/.claude.json
--   base_url falls back to $JIRA_BASE_URL, then https://jiraeu.epam.com
-- M.jira = {
--   enabled  = true,
--   base_url = "https://jiraeu.epam.com",
--   token    = "…",
-- }

-- GitLab token for the :ReviewMR source-branch lookup (only used when
-- jira.enabled). Falls back to $GITLAB_TOKEN, then GITLAB_TOKEN in a .env at the
-- repo root / its parents (where the nbs-art clones keep it).
-- M.gitlab = {
--   token = "…",   -- GitLab personal access token (sent as PRIVATE-TOKEN)
-- }

-- Voice dictation (F10) engine: "vosk" (default, offline model) or "macos"
-- (on-device Speech framework via the `hear` CLI — `brew install hear`).
-- M.dictation_engine = "macos"
-- Extra args passed to `hear` (default { "-d", "-p" } = on-device + punctuation).
-- M.dictation_hear_args = { "-d", "-p" }   -- drop "-p" if your locale lacks it

-- Review view (nvim-tree `gR`): red/green patch view of <base>...HEAD with a
-- file sidebar. Selecting a file (⏎) shows its unified diff and runs ALL the
-- checkers below asynchronously; `r` re-runs them. Each checker must print lines
-- of the form `LOC: <file>:<line> <message>` on stdout — they are mapped onto the
-- rows of the diff buffer and merged into one quickfix list (navigate with ]q/[q).
--
-- Each checker:
--   name   label shown in findings (prefixed as "[name] ...")
--   cmd    argv table; ${file} = absolute path, ${path} = repo-relative path
--   input  what is piped to stdin: "prompt" (AI review prompt + diff),
--          "diff" (raw unified diff), or "none" (default "prompt")
--   env    optional extra environment variables
--
-- If omitted, a single "ai" checker is built from M.diff_review (claude_command/
-- model/env) using input="prompt".
-- M.review_view = {
--   checkers = {
--     -- AI agent review of the diff
--     {
--       name  = "ai",
--       cmd   = { vim.fn.expand("~/.local/bin/claude"), "-p", "--no-session-persistence" },
--       input = "prompt",
--       env   = { CLAUDECODE = "" },
--     },
--     -- A linter wrapper that takes the file path and prints LOC: lines
--     -- { name = "ruff", cmd = { vim.fn.expand("~/.config/nvim/scripts/ruff-loc"), "${file}" }, input = "none" },
--     -- A tool that reads the unified diff on stdin
--     -- { name = "diffcheck", cmd = { "my-diff-checker" }, input = "diff" },
--   },
-- }

-- Kitty drop (<leader>kd / <leader>kf): send text from nvim into another kitty
-- window — the Claude Code TUI in a separate tab. Requires kitty started with
-- `allow_remote_control yes` + `listen_on unix:...` (so KITTY_LISTEN_ON is set).
-- The first drop asks which kitty window to send to and remembers it; later drops
-- reuse it on a single Enter (press `n` at the prompt to pick another). To skip the
-- prompt, pin a fixed kitty --match expression below.
-- M.kitty_drop = {
--   match = "cmdline:claude",  -- pin a kitty --match expr; skips the picker entirely
-- }

-- Agenda builder: web pages to scrape for context. Each entry is { name, url }.
-- Add your own corporate dashboards, profile pages, etc. URLs may contain
-- personal IDs — keep this file git-ignored.
M.agenda = {
  web_pages = {
    -- { "Workplace", "https://your-portal.example.com/workplace" },
    -- { "Learning",  "https://learn.example.com/myLearning" },
  },
}

M.keybindings = {}

function M.keybindings.apply(map)
  map("n", "`", "<cmd>NvimTreeToggle<CR>", { desc = "Toggle tree (local)" })
  map("n", "§", "<cmd>NvimTreeToggle<CR>", { desc = "Toggle tree (local)" })
end

return M
