return {
  "nvim-lualine/lualine.nvim",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  event = "VeryLazy",
  config = function()
    -- Respect the nerd-font toggle from settings_local (default: icons on).
    local icons = require("config.settings").get("nerd_font_icons") ~= false

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
        lualine_c = {
          { "filename", path = 1 }, -- relative path
          -- For review_view diff panes: show which version is on screen
          -- (live / @<sha>) right beside the file path. Empty elsewhere.
          {
            function()
              local ok, rv = pcall(require, "config.review_view")
              return ok and rv.view_tag_for and rv.view_tag_for() or ""
            end,
            cond = function()
              local ok, rv = pcall(require, "config.review_view")
              return ok and rv.view_tag_for and rv.view_tag_for() ~= ""
            end,
            icon = "",
          },
        },
        lualine_x = { "filetype" },
        lualine_y = { "progress" },
        lualine_z = { "location" },
      },
      extensions = { "nvim-tree", "aerial", "trouble", "quickfix", "fugitive" },
    })
  end,
}
