return {
  "nvim-tree/nvim-tree.lua",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  config = function()
    local ok, settings_local = pcall(require, "config.settings_local")
    local nerd_icons = not (ok and type(settings_local) == "table" and settings_local.nerd_font_icons == false)
    local git_base = (ok and type(settings_local) == "table" and settings_local.git_base_branch) or "main"

    require("nvim-tree").setup({
      filters = {
        dotfiles = false,            -- показывать файлы, начинающиеся с точки
        git_ignored = false,         -- отключить фильтрацию .gitignore
      },
      git = {
        ignore = false,              -- также отключает глобальную фильтрацию gitignore
        timeout = 5000,              -- default 400ms is too short and crashes utils.lua:15 with nil obj
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
        -- жмём "gB" => diffview против базовой ветки для репо под курсором
        local function resolve_base(toplevel)
          local function verify(ref)
            vim.fn.systemlist({ "git", "-C", toplevel, "rev-parse", "--verify", "--quiet", ref })
            return vim.v.shell_error == 0
          end
          local candidates = { git_base, "origin/" .. git_base }
          for _, b in ipairs({ "main", "master", "develop" }) do
            if b ~= git_base then
              table.insert(candidates, b)
              table.insert(candidates, "origin/" .. b)
            end
          end
          for _, c in ipairs(candidates) do
            if verify(c) then return c end
          end
          local out = vim.fn.systemlist({ "git", "-C", toplevel, "symbolic-ref", "--short", "refs/remotes/origin/HEAD" })
          if vim.v.shell_error == 0 and out[1] and out[1] ~= "" then
            return out[1]
          end
          return nil
        end

        vim.keymap.set("n", "gB", function()
          local node = api.tree.get_node_under_cursor()
          if not (node and node.absolute_path) then return end
          local path = node.absolute_path
          local dir = vim.fn.isdirectory(path) == 1 and path or vim.fn.fnamemodify(path, ":h")
          local out = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "--show-toplevel" })
          if vim.v.shell_error ~= 0 or not out[1] or out[1] == "" then
            vim.notify("Not a git repo: " .. dir, vim.log.levels.WARN)
            return
          end
          local toplevel = out[1]
          local base = resolve_base(toplevel)
          if not base then
            vim.notify("No base branch found (tried " .. git_base .. ", main, master, develop, origin/HEAD)", vim.log.levels.WARN)
            return
          end
          local branch_out = vim.fn.systemlist({ "git", "-C", toplevel, "symbolic-ref", "--short", "HEAD" })
          local head_ref = (vim.v.shell_error == 0 and branch_out[1] and branch_out[1] ~= "") and branch_out[1] or "HEAD"
          vim.cmd("DiffviewOpen -C" .. vim.fn.fnameescape(toplevel) .. " " .. base .. "..." .. head_ref)
        end, opts("Diffview: vs base branch"))
        -- жмём "T" => открыть shared-терминал в выбранной папке, фокус остаётся в tree
        vim.keymap.set("n", "T", function()
          local node = api.tree.get_node_under_cursor()
          if node and node.absolute_path then
            require("config.shared_term").cd(node.absolute_path)
          end
        end, opts("Terminal here (keep focus)"))
        -- "\T" => то же самое, но переключает фокус на терминал
        vim.keymap.set("n", "<leader>T", function()
          local node = api.tree.get_node_under_cursor()
          if node and node.absolute_path then
            require("config.shared_term").cd(node.absolute_path, { focus = true })
          end
        end, opts("Terminal here (focus term)"))
      end,

      -- остальная твоя конфигурация, если есть
      view = {
        width = 35,
      },
      renderer = {
        icons = {
          web_devicons = {
            file = { enable = nerd_icons, color = nerd_icons },
            folder = { enable = nerd_icons, color = nerd_icons },
          },
          show = { file = nerd_icons, folder = true, folder_arrow = true, git = true },
          glyphs = (not nerd_icons) and {
            default = "",
            symlink = "@",
            bookmark = "*",
            modified = "+",
            folder = {
              arrow_closed = ">",
              arrow_open = "v",
              default = "+",
              open = "-",
              empty = " ",
              empty_open = " ",
              symlink = "@",
              symlink_open = "@",
            },
            git = {
              unstaged = "M", staged = "+", unmerged = "!",
              renamed = "R", untracked = "?", deleted = "D", ignored = "I",
            },
          } or nil,
        },
      },
    })

  end,
}
