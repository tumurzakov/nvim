return {
  "altercation/vim-colors-solarized",
  lazy = false,
  priority = 1000,
  config = function()
    vim.o.background = "light" -- Solarized Light
    vim.g.solarized_termtrans = 1 -- Use terminal background
    vim.cmd.colorscheme("solarized")
  end,
}

