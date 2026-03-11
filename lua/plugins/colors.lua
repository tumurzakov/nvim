return {
  "altercation/vim-colors-solarized",
  lazy = false,
  priority = 1000,
  config = function()
    vim.o.background = "light" -- Solarized Light
    vim.g.solarized_termtrans = 1 -- Use terminal background
    vim.cmd.colorscheme("solarized")

    -- Solarized terminal colors (for :terminal buffers)
    vim.g.terminal_color_0  = "#073642" -- base02
    vim.g.terminal_color_1  = "#dc322f" -- red
    vim.g.terminal_color_2  = "#859900" -- green
    vim.g.terminal_color_3  = "#b58900" -- yellow
    vim.g.terminal_color_4  = "#268bd2" -- blue
    vim.g.terminal_color_5  = "#d33682" -- magenta
    vim.g.terminal_color_6  = "#2aa198" -- cyan
    vim.g.terminal_color_7  = "#eee8d5" -- base2
    vim.g.terminal_color_8  = "#002b36" -- base03
    vim.g.terminal_color_9  = "#cb4b16" -- orange
    vim.g.terminal_color_10 = "#586e75" -- base01
    vim.g.terminal_color_11 = "#657b83" -- base00
    vim.g.terminal_color_12 = "#839496" -- base0
    vim.g.terminal_color_13 = "#6c71c4" -- violet
    vim.g.terminal_color_14 = "#93a1a1" -- base1
    vim.g.terminal_color_15 = "#fdf6e3" -- base3
  end,
}

