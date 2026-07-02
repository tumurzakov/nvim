return {
  "nvim-tree/nvim-tree.lua",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  config = function()
    local ok, settings_local = pcall(require, "config.settings_local")
    local nerd_icons = not (ok and type(settings_local) == "table" and settings_local.nerd_font_icons == false)

    -- Subtle highlight for the inline branch label next to repo folders.
    vim.api.nvim_set_hl(0, "NvimTreeGitBranch", { link = "Comment", default = true })
    local git_branch_decorator = require("config.tree_git_branch").decorator()

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

        -- floating git info popup when the cursor is on a repo folder
        require("config.tree_git_popup").attach(bufnr)

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
        -- "gb" => add distance from origin's default branch to the git popup
        vim.keymap.set("n", "gb", function()
          require("config.tree_git_popup").show_distance()
        end, opts("Git: distance from default branch"))
        -- "gB" => floating branch switcher for the repo under the cursor
        vim.keymap.set("n", "gB", function()
          local node = api.tree.get_node_under_cursor()
          if not node or not node.absolute_path then return end
          local dir = node.type == "directory" and node.absolute_path
            or vim.fn.fnamemodify(node.absolute_path, ":h")
          require("config.tree_git_switch").switch(dir)
        end, opts("Git: switch branch (float)"))
        -- жмём "t" => открыть в новом табе
        vim.keymap.set("n", "t", api.node.open.tab, opts("Open in new tab"))
        -- жмём "gR" => red/green patch-review view (feature vs base) с in-buffer quickfix
        vim.keymap.set("n", "gR", function()
          local node = api.tree.get_node_under_cursor()
          if node and node.absolute_path then
            require("config.review_view").open_from_node(node)
          end
        end, opts("Review: feature vs base (red/green)"))
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
        -- builtins (default order) + our branch label after repo folders
        decorators = {
          "Git", "Open", "Hidden", "Modified", "Bookmark", "Diagnostics", "Copied", "Cut",
          git_branch_decorator,
        },
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

    -- Keep the inline branch labels fresh: the decorator only runs on render, so
    -- a checkout done elsewhere (terminal, another window) leaves a stale label.
    -- Reload the tree when nvim regains focus or you re-enter it — debounced and
    -- rate-limited to at most once per 2s, and only when the tree is visible, so
    -- it never churns the UI while you navigate.
    local uv = vim.uv or vim.loop
    local last_reload = 0
    local function maybe_reload()
      local api = require("nvim-tree.api")
      local ok, visible = pcall(api.tree.is_visible)
      if not ok or not visible then return end
      if uv.now() - last_reload < 2000 then return end
      last_reload = uv.now()
      pcall(api.tree.reload)
    end
    local grp = vim.api.nvim_create_augroup("user.tree.branch_refresh", { clear = true })
    vim.api.nvim_create_autocmd({ "FocusGained", "TermClose", "TermLeave" }, {
      group = grp,
      callback = function() vim.schedule(maybe_reload) end,
    })
    vim.api.nvim_create_autocmd("BufEnter", {
      group = grp,
      pattern = "NvimTree_*",
      callback = function() vim.schedule(maybe_reload) end,
    })
  end,
}
