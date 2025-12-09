-- General keymaps
vim.keymap.set("n", "<leader>e", ":Ex<CR>")         -- File explorer
vim.keymap.set("i", "jk", "<Esc>")                  -- Fast exit insert mode

-- NERDTree-like toggle for nvim-tree on tilde
vim.keymap.set("n", "`", ":NvimTreeToggle<CR>", { silent = true, noremap = true, desc = "Toggle tree" })

-- CodeCompanion
local function cc_get_visual_selection()
  local bufnr = 0
  local start_pos = vim.api.nvim_buf_get_mark(bufnr, "<")
  local end_pos = vim.api.nvim_buf_get_mark(bufnr, ">")
  if start_pos[1] == 0 or end_pos[1] == 0 then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_pos[1] - 1, end_pos[1], false)
  if vim.tbl_isempty(lines) then
    return nil
  end
  lines[#lines] = string.sub(lines[#lines], 1, end_pos[2] + 1)
  lines[1] = string.sub(lines[1], start_pos[2] + 1)
  return table.concat(lines, "\n")
end

local function cc_open_chat_with_selection()
  local mode = vim.fn.mode()
  local has_selection = mode:match("[vV\22]") ~= nil
  local selection = has_selection and cc_get_visual_selection() or nil

  if has_selection then
    -- exit visual to avoid clobbering the next commands
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
  end

  local cc = require("codecompanion")
  local chat = cc.chat({
    messages = selection and { { role = "user", content = selection } } or nil,
    auto_submit = false,
  })

  -- Focus input for immediate typing
  vim.schedule(function()
    if chat and chat.ui and chat.ui.win and vim.api.nvim_win_is_valid(chat.ui.win) then
      vim.api.nvim_set_current_win(chat.ui.win)
    end
    vim.cmd("startinsert")
  end)
end

vim.keymap.set({ "n", "v" }, "<C-l>", cc_open_chat_with_selection, { silent = true, noremap = true, desc = "CodeCompanion Chat (with selection)" })
vim.keymap.set("n", "<leader>cc", ":CodeCompanionChat<CR>", { silent = true, noremap = true, desc = "CodeCompanion Chat" })
vim.keymap.set("v", "<leader>ca", ":CodeCompanionActions<CR>", { silent = true, noremap = true, desc = "CodeCompanion Actions" })

-- Errors
vim.o.updatetime = 300  -- задержка перед показом (мс)

-- vim.api.nvim_create_autocmd("CursorHold", {
--   callback = function()
--     vim.diagnostic.open_float(nil, { focus = false })
--   end,
-- })

vim.api.nvim_create_autocmd("CursorHold", {
  callback = function()
    local opts = {
      focusable = false,
      close_events = { "BufLeave", "CursorMoved", "InsertEnter", "FocusLost" },
      border = "rounded",
      source = "always",
      prefix = " ",
      scope = "cursor",
    }
    vim.diagnostic.open_float(nil, opts)
  end,
})
