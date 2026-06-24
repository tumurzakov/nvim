return {
  "nvim-lualine/lualine.nvim",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  event = "VeryLazy",
  config = function()
    -- Respect the nerd-font toggle from settings_local (default: icons on).
    local ok, sl = pcall(require, "config.settings_local")
    local icons = not (ok and type(sl) == "table" and sl.nerd_font_icons == false)

    require("lualine").setup({
      options = {
        theme = "solarized_light", -- matches the Solarized Light colorscheme
        icons_enabled = icons,
        section_separators = icons and { left = "", right = "" } or { left = "", right = "" },
        component_separators = icons and { left = "", right = "" } or { left = "|", right = "|" },
        globalstatus = true, -- one statusline across all splits (laststatus=3)
      },
      sections = {
        lualine_a = { "mode" },
        lualine_b = { "branch", "diff", "diagnostics" },
        lualine_c = { { "filename", path = 1 } }, -- relative path
        lualine_x = { "filetype" },
        lualine_y = { "progress" },
        lualine_z = { "location" },
      },
      extensions = { "nvim-tree", "aerial", "trouble", "quickfix", "fugitive" },
    })
  end,
}
