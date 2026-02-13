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
      on_attach = function(bufnr)
        local api = require("nvim-tree.api")

        -- сначала ставим дефолтные бинды, чтобы ничего не сломать
        api.config.mappings.default_on_attach(bufnr)

        -- удобная helper-функция для опций
        local function opts(desc)
          return {
            desc = "nvim-tree: " .. desc,
            buffer = bufnr,
            noremap = true,
            silent = true,
            nowait = true,
          }
        end

        -- ТУТ главное:
        -- В нормальном режиме внутри nvim-tree:
        -- жмём "p" => preview without leaving tree focus
        vim.keymap.set("n", "p", api.node.open.preview_no_picker, opts("Preview (keep focus)"))
        -- жмём "t" => открыть в новом табе
        vim.keymap.set("n", "t", api.node.open.tab, opts("Open in new tab"))
        -- при желании можно ещё добавить "T" на tab drop:
        -- vim.keymap.set("n", "T", api.node.open.tab_drop, opts("Open: Tab drop"))
      end,

      -- остальная твоя конфигурация, если есть
      view = {
        width = 35,
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
