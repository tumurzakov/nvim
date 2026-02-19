-- Copy this file to lua/config/keybindings_local.lua (git-ignored)
-- and customize per machine/keyboard layout.

local M = {}

function M.apply(map)
  map("n", "`", "<cmd>NvimTreeToggle<CR>", { desc = "Toggle tree (local)" })
  map("n", "§", "<cmd>NvimTreeToggle<CR>", { desc = "Toggle tree (local)" })
end

return M
