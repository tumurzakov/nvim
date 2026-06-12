local M = {}

local help_text = [[
 Keybindings (Leader = \)              Press q/Esc to close

 FILES            LSP                  AI (CodeCompanion)
 \e   Explorer    gd  Definition       C-l  Chat / paste sel
 \tt  NvimTree    gr  References       C-k  Explain (hover)
 ±/~  Tree focus  gi  Implementation   A-l  Toggle chat
 \ff  Find files  K   Hover info       \ci  Rewrite (visual)
 \fg  Live grep   \rn Rename           \cc  Chat
 \fb  Buffers     \ca Code action      \cm  Commit message
 \fh  Help tags   \f  Format           \ca  Actions (visual)
 F9   Aerial                           \cq  Review Q (visual, Diffview-aware)
                                       /diff in chat: insert git diff

 TERMINAL (C-b prefix)                 PYTHON & TESTING
 C-b n/p  Next/prev tab                \ta  Pytest all
 C-b c    New tab                      \tf  Pytest file
 \rl      Run current line             \tn  Pytest nearest
 \r       Run selection (visual)       \rx  Ruff fix
 T        Tree: term here (keep tree)  \x   Run file
 \T       Tree: term here (focus term)

 WINDOW           SPEECH               WEB
 F3   Zoom split  \ss  Speak sel       \ws  Summarize web page
                  \sq  Stop speaking

 GIT (Diffview)
 \gd  All changes (diffview)           \gc  Close review view / diffview
 \gh  File history                     \gH  Branch history
 gd   File diff (in tree)              gB   Diff vs base branch (in tree)
 gR   Patch review (red/green; r=review ]q/[q=nav Tab=fold zM/zR=all)
 \kd  Drop sel/file:line → Claude kitty tab   \kf  Drop file path

 \cr  DiffReview (AI review → inline + quickfix; auto on file open)
 \cR  DiffReview: clear all     \xQ  Browse issues (quickfix)

 DIAGNOSTICS (Trouble)
 \xx  Workspace diagnostics            \xs  Symbols
 \xX  Buffer diagnostics               \xl  LSP refs/definitions
 \xQ  Quickfix list                    \xL  Location list
 [x / ]x  Prev / next item

 EDITING          COMPLETION (insert)  COMMANDS
 jk  Leave insert C-Space Trigger      :ReloadConfig
                  Enter   Confirm      :CC  CodeCompanion
                  C-e     Abort        :Agenda [date]
                                       :Cheatsheet
]]

function M.show()
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(help_text, "\n")

  -- Append recent project files
  local cwd = vim.fn.getcwd()
  local recent = {}
  for _, f in ipairs(vim.v.oldfiles or {}) do
    if #recent >= 3 then break end
    if vim.startswith(f, cwd .. "/") and vim.fn.filereadable(f) == 1 then
      table.insert(recent, f:sub(#cwd + 2))
    end
  end
  if #recent > 0 then
    table.insert(lines, " Recent files (project):")
    for i, f in ipairs(recent) do
      table.insert(lines, " " .. i .. ". " .. f)
    end
    table.insert(lines, "")
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "help_cheatsheet"

  -- Calculate popup size
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width + 2, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 4)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Cheatsheet ",
    title_pos = "center",
  })

  -- Close on any key press
  local close = function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<CR>", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Space>", close, { buffer = buf, nowait = true })

  -- Open recent file by number
  for i, f in ipairs(recent) do
    vim.keymap.set("n", tostring(i), function()
      close()
      vim.cmd("edit " .. vim.fn.fnameescape(cwd .. "/" .. f))
    end, { buffer = buf, nowait = true })
  end
end

function M.setup()
  vim.api.nvim_create_user_command("Cheatsheet", M.show, {
    desc = "Show custom keybindings cheatsheet",
  })
end

return M
