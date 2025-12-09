-- General keymaps
vim.keymap.set("n", "<leader>e", ":Ex<CR>")         -- File explorer
vim.keymap.set("i", "jk", "<Esc>")                  -- Fast exit insert mode

-- NERDTree-like toggle for nvim-tree on tilde
vim.keymap.set("n", "`", ":NvimTreeToggle<CR>", { silent = true, noremap = true, desc = "Toggle tree" })

-- CodeCompanion
vim.keymap.set("n", "<leader>cc", ":CodeCompanionChat<CR>", { silent = true, noremap = true, desc = "CodeCompanion Chat" })
vim.keymap.set("v", "<leader>ca", ":CodeCompanionActions<CR>", { silent = true, noremap = true, desc = "CodeCompanion Actions" })
