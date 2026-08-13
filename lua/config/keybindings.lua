-- Keybindings. Feature logic lives in the config.* modules (run_terminal,
-- python_run, tts, codecompanion_actions, reload, …) — this file only maps keys
-- and keeps a few small window/UI helpers.
local default_opts = { noremap = true, silent = true }

local function map(mode, lhs, rhs, opts)
  vim.keymap.set(mode, lhs, rhs, vim.tbl_extend("force", default_opts, opts or {}))
end

local function open_diagnostics_float()
  vim.diagnostic.open_float(nil, {
    focusable = false,
    close_events = { "BufLeave", "CursorMoved", "InsertEnter", "FocusLost" },
    border = "rounded",
    source = "always",
    prefix = " ",
    scope = "cursor",
  })
end

local function telescope_call(picker)
  return function()
    local ok, builtin = pcall(require, "telescope.builtin")
    if not ok then
      vim.notify("Telescope is not available", vim.log.levels.ERROR)
      return
    end
    builtin[picker]()
  end
end

-- Toggle zoom current split
local function toggle_zoom()
  if vim.t.zoomed then
    vim.cmd(vim.t.zoom_restore)
    vim.t.zoomed = false
  else
    vim.t.zoom_restore = vim.fn.winrestcmd()
    vim.cmd("wincmd _")
    vim.cmd("wincmd |")
    vim.t.zoomed = true
  end
end

-- Toggle focus between NvimTree and source window
local last_source_win = nil
local function toggle_nvimtree_focus()
  local nvimtree_api_ok, nvimtree_api = pcall(require, "nvim-tree.api")
  if not nvimtree_api_ok then
    return
  end

  local cur_win = vim.api.nvim_get_current_win()
  local cur_buf = vim.api.nvim_win_get_buf(cur_win)
  local is_tree = vim.bo[cur_buf].filetype == "NvimTree"

  if is_tree then
    -- Go back to source window
    if last_source_win and vim.api.nvim_win_is_valid(last_source_win) then
      vim.api.nvim_set_current_win(last_source_win)
    else
      vim.cmd("wincmd l")
    end
  else
    -- Remember source window, then focus tree (open if needed)
    last_source_win = cur_win
    local tree_visible = nvimtree_api.tree.is_visible()
    if tree_visible then
      nvimtree_api.tree.focus()
    else
      nvimtree_api.tree.open()
    end
  end
end

-- Core keybindings
map("n", "<leader>e", "<cmd>Ex<CR>", { desc = "File explorer" })
map("i", "jk", "<Esc>", { desc = "Leave insert mode" })
-- Visual y yanks to the system clipboard by DEFAULT, but respects an explicit
-- register when you give one — so "ay still yanks into register a. Normal-mode
-- y/yy and deletes are untouched.
map("x", "y", function()
  return (vim.v.register == '"') and '"+y' or ('"' .. vim.v.register .. 'y')
end, { expr = true, desc = "Yank to clipboard (or the given register)" })
map("n", "<leader>tt", "<cmd>NvimTreeToggle<CR>", { desc = "Toggle tree" })
map("n", "±", toggle_nvimtree_focus, { desc = "Toggle NvimTree focus" })
map("n", "<F3>", toggle_zoom, { desc = "Toggle zoom split" })
map("n", "<F9>", "<cmd>AerialToggle!<CR>", { desc = "Toggle aerial" })
map("n", "<leader>ff", telescope_call("find_files"), { desc = "Find files (Telescope)" })
map("n", "<leader>fg", telescope_call("live_grep"), { desc = "Live grep (Telescope)" })
map("n", "<leader>fb", telescope_call("buffers"), { desc = "Buffers (Telescope)" })
map("n", "<leader>fh", telescope_call("help_tags"), { desc = "Help tags (Telescope)" })

-- Repo terminal: \T from a normal file opens/focuses the shared terminal for
-- the current file's git repo; pressing it again from that terminal jumps back
-- to the file. (In nvim-tree, \T is buffer-local and acts on the node instead.)
map("n", "<leader>T", function()
  local st = require("config.shared_term")
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo.buftype == "terminal" and st.is_shared(buf) then
    if not st.toggle_back() then vim.cmd("wincmd p") end   -- back to the file
    return
  end
  local G = require("config.git")
  local dir = G.buf_dir()
  st.cd(G.root(dir) or dir, { focus = true })
end, { desc = "Repo terminal: focus / back (\\T)" })

-- Terminal switcher: floating picker → show chosen terminal in the right window
map("n", "<F4>", function() require("config.term_switcher").pick() end, { desc = "Switch terminal (floating picker)" })

-- ...also reachable from INSIDE a terminal: leave terminal mode, then pick.
-- F4 (same key everywhere) and the <C-\>m chord (next to the <C-\><C-n> exit).
local function switch_terminal_from_term()
  require("config.vim_util").leave_terminal_mode()
  vim.schedule(function() require("config.term_switcher").pick() end)
end
map("t", "<F4>", switch_terminal_from_term, { desc = "Switch terminal (from terminal mode)" })
map("t", "<C-\\>m", switch_terminal_from_term, { desc = "Switch terminal (from terminal mode)" })

-- Markdown
map("n", "<leader>mm", function() require("config.md_server").open() end, { desc = "Markdown view (HTTP server, live)" })
map("n", "<leader>ms", function() require("config.md_server").stop() end, { desc = "Markdown server stop" })

-- CodeCompanion
map({ "n", "v" }, "<C-l>", function() require("config.codecompanion_actions").chat_with_selection() end,
  { desc = "CodeCompanion chat with selection" })
map({ "n", "v" }, "<C-k>", function() require("config.codecompanion_k").short_explain() end,
  { desc = "CodeCompanion short explain (K window)" })
map("v", "<leader>ci", function() require("config.codecompanion_actions").rewrite_selection() end,
  { desc = "Rewrite selected text (CodeCompanion)" })
map("v", "<leader>cq", function() require("config.codecompanion_actions").review_question() end,
  { desc = "CodeCompanion review question (base..HEAD)" })
map("n", "<leader>cc", "<cmd>CodeCompanionChat<CR>", { desc = "CodeCompanion chat" })
map("n", "<A-l>", "<cmd>CodeCompanionChat Toggle<CR>", { desc = "Toggle CodeCompanion chat" })
map("n", "¬", "<cmd>CodeCompanionChat Toggle<CR>", { desc = "Toggle CodeCompanion chat" })
map("n", "<leader>cm", "<cmd>CodeCompanion /commit<CR>", { desc = "CodeCompanion commit message" })
map("v", "<leader>ca", "<cmd>CodeCompanionActions<CR>", { desc = "CodeCompanion actions" })

-- Close the red/green (gR) review view if it's open
map("n", "<leader>gc", function() require("config.review_view").close() end, { desc = "Close review view" })

-- Kitty drop: send text into the tagged Claude Code kitty window
map("v", "<leader>kd", function()
  -- leave visual mode so '< / '> marks are committed, then send
  require("config.vim_util").leave_visual_mode()
  require("config.kitty_drop").send_visual()
end, { desc = "Kitty drop: send selection to Claude tab" })
map("n", "<leader>kd", function() require("config.kitty_drop").send_lineref() end, { desc = "Kitty drop: send file:line to Claude tab" })
map("n", "<leader>kf", function() require("config.kitty_drop").send_path() end, { desc = "Kitty drop: send file path to Claude tab" })

-- Diagnostics (updatetime lives in config.options)
vim.api.nvim_create_autocmd("CursorHold", { callback = open_diagnostics_float })

-- Terminal tab navigation
map("t", "<C-b>n", function()
  require("config.vim_util").leave_terminal_mode()
  require("config.run_terminal").tab_next(1)
end)

map("t", "<C-b>p", function()
  require("config.vim_util").leave_terminal_mode()
  require("config.run_terminal").tab_next(-1)
end)

map("n", "<C-b>n", function() require("config.run_terminal").tab_next(1) end)
map("n", "<C-b>p", function() require("config.run_terminal").tab_next(-1) end)
map("n", "<C-b>c", function() require("config.run_terminal").new_tab() end, { desc = "Open terminal tab" })
map("v", "<leader>r", function() require("config.run_terminal").run_selection() end, { desc = "Run selection in terminal" })
map("n", "<leader>rl", function() require("config.run_terminal").run_line() end, { desc = "Run current line in terminal" })

-- Python tools (prefer Poetry when available)
map("n", "<leader>ta", function() require("config.python_run").pytest_all() end, { desc = "Pytest all" })
map("n", "<leader>tf", function() require("config.python_run").pytest_file() end, { desc = "Pytest file" })
map({ "n", "v" }, "<leader>tn", function() require("config.python_run").pytest_nearest() end, { desc = "Pytest nearest" })
map("n", "<leader>rx", function() require("config.python_run").ruff_fix_current_file() end, { desc = "Ruff check --fix" })
map("n", "<leader>x", function() require("config.python_run").run_current_script() end, { desc = "Run current Python file" })

-- Text-to-speech (config.tts):
--   F8 (normal): speak from the cursor line to end of buffer; press again to stop.
--   F8 / \ss (visual): speak the selection.
--   \sq: stop.
map("n", "<F8>", function() require("config.tts").toggle_read_from_cursor() end, { desc = "TTS: read from cursor / stop" })
map("v", "<F8>", function() require("config.tts").speak_selection_mapping() end, { desc = "TTS: speak selection" })
map("v", "<leader>ss", function() require("config.tts").speak_selection_mapping() end, { desc = "TTS: speak selection" })
map({ "n", "v" }, "<leader>sq", function() require("config.tts").stop() end, { desc = "TTS: stop speaking" })

-- :ReloadConfig
require("config.reload")

-- Local (git-ignored) settings overrides: lua/config/settings_local.lua
local kb = require("config.settings").get("keybindings")
if type(kb) == "table" and type(kb.apply) == "function" then
  kb.apply(map)
end
