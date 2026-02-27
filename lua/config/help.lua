local M = {}

local help_text = [[
 Keybindings (Leader = \)              Press q/Esc to close

 FILES            LSP                  AI (CodeCompanion)
 \e   Explorer    gd  Definition       C-l  Chat / paste sel
 \tt  NvimTree    gr  References       C-k  Explain (hover)
 \ff  Find files  gi  Implementation   \ci  Rewrite (visual)
 \fg  Live grep   K   Hover info       \cc  Chat
 \fb  Buffers     \rn Rename           \cm  Commit message
 \fh  Help tags   \ca Code action      \ca  Actions (visual)
 F9   Aerial      \f  Format

 TERMINAL (C-b prefix)                 PYTHON & TESTING
 C-b n/p  Next/prev tab               \ta  Pytest all
 C-b c    New tab                      \tf  Pytest file
 C-b v    Vsplit                       \tn  Pytest nearest
 \r       Toggle split / run sel       \rx  Ruff fix
 \rv      Toggle vsplit                \x   Run file

 EDITING          COMPLETION (insert)  COMMANDS
 jk  Leave insert C-Space Trigger      :ReloadConfig
                  Enter   Confirm      :CC  CodeCompanion
                  C-e     Abort        :Cheatsheet
]]

function M.show()
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(help_text, "\n")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "help_cheatsheet"

  vim.api.nvim_set_current_buf(buf)

  -- Close on any key press
  local close = function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end

  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<CR>", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Space>", close, { buffer = buf, nowait = true })
end

function M.setup()
  vim.api.nvim_create_user_command("Cheatsheet", M.show, {
    desc = "Show custom keybindings cheatsheet",
  })

  -- Show on startup when no files were given as arguments
  vim.api.nvim_create_autocmd("VimEnter", {
    callback = function()
      -- Only show when nvim was opened with no file arguments
      if vim.fn.argc() == 0 then
        -- Defer so the UI is fully drawn first
        vim.schedule(M.show)
      end
    end,
  })
end

return M
