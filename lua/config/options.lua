-- Leader key
vim.g.mapleader = "\\"
vim.g.maplocalleader = "\\"

-- Persistent undo
vim.opt.undofile = true

-- Russian keyboard layout support in Normal/Visual/Operator-pending modes
vim.opt.langmap = table.concat({
  "ФИСВУАПРШОЛДЬТЩЗЙКЫЕГМЦЧНЯ;ABCDEFGHIJKLMNOPQRSTUVWXYZ",
  "фисвуапршолдьтщзйкыегмцчня;abcdefghijklmnopqrstuvwxyz",
  "Ж:,ж\\;,Б<,Ю>,б\\,,ю.",
}, ",")

-- Basic settings
vim.o.number = true
vim.o.relativenumber = true
vim.o.tabstop = 4
vim.o.shiftwidth = 4
vim.o.expandtab = true
vim.o.termguicolors = true

-- Folding via LSP
vim.o.foldmethod = "expr"
vim.o.foldexpr = "v:lua.vim.lsp.foldexpr()"
vim.o.foldlevel = 99

-- Use bash on Windows (MSYS2/Git Bash) so :terminal and chansend work correctly
if vim.fn.has("win32") == 1 then
  vim.o.shell = "bash"
  vim.o.shellcmdflag = "-c"
  vim.o.shellquote = ""
  vim.o.shellxquote = ""
end

-- nvim-tree: disable netrw to avoid conflicts
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1
