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
        -- оставляем "p" под дефолтный paste (нужно для c + p),
        -- а preview переносим на "P"
        vim.keymap.set("n", "P", api.node.open.preview_no_picker, opts("Preview (keep focus)"))
        -- жмём "t" => открыть в новом табе
        vim.keymap.set("n", "t", api.node.open.tab, opts("Open in new tab"))
        -- жмём "gd" => открыть diffview для файла (рабочие изменения)
        vim.keymap.set("n", "gd", function()
          local node = api.tree.get_node_under_cursor()
          if node and node.absolute_path then
            vim.cmd("DiffviewOpen -- " .. vim.fn.fnameescape(node.absolute_path))
          end
        end, opts("Diffview: file diff"))
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
