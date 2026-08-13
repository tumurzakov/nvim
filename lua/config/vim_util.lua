-- Tiny mode/selection helpers shared by keybindings and the feature modules.
local M = {}

function M.feedkeys(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "n", false)
end

function M.feedkeys_sync(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "nx", false)
end

function M.leave_visual_mode()
  M.feedkeys_sync("<Esc>")
end

function M.leave_terminal_mode()
  M.feedkeys("<C-\\><C-n>")
end

-- The last visual selection, read from the '< / '> marks (so visual mode must
-- have been left first). Returns nil when there is no selection.
function M.visual_selection()
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

-- The current visual selection, captured by yanking into a scratch register
-- (works while still in visual mode; register z is preserved).
function M.visual_text()
  local reg_z = vim.fn.getreginfo("z")
  vim.cmd('silent normal! "zy')
  local text = vim.fn.getreg("z")
  vim.fn.setreg("z", reg_z)
  return text
end

return M
