return {
  "nvim-tree/nvim-tree.lua",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  config = function()
    require("nvim-tree").setup({
      renderer = {
        icons = {
          -- Use Nerd Font icons for files and folders
          web_devicons = {
            file = { enable = true, color = true },
            folder = { enable = true, color = true },
          },
          show = { file = true, folder = true, folder_arrow = true, git = true },
        },
      },
    })
  end,
}
