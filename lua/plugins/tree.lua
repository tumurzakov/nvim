return {
  "nvim-tree/nvim-tree.lua",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  config = function()
    require("nvim-tree").setup({
      filters = {
        dotfiles = false,            -- показывать файлы, начинающиеся с точки
        git_ignored = false,         -- отключить фильтрацию .gitignore
      },
      git = {
        ignore = false,              -- также отключает глобальную фильтрацию gitignore
      },
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
