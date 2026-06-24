return {
  "nvim-treesitter/nvim-treesitter",
  lazy = false,
  build = ":TSUpdate",
  dependencies = {
    { "nvim-treesitter/nvim-treesitter-textobjects", branch = "main" },
  },
  config = function()
    local ok, ts = pcall(require, "nvim-treesitter")
    if not ok then
      vim.notify("nvim-treesitter is not available", vim.log.levels.WARN)
      return
    end

    ts.setup({})

    -- Needed by CodeCompanion markdown prompt library parser.
    pcall(function()
      ts.install({ "lua", "python", "yaml", "json", "markdown", "markdown_inline", "vim", "vimdoc", "query" })
    end)

    -- Enable treesitter highlighting globally
    vim.api.nvim_create_autocmd("FileType", {
      callback = function(args)
        pcall(vim.treesitter.start, args.buf)
      end,
    })

    -- Treesitter text objects (function / class / argument) + motions + swap.
    local okto = pcall(require, "nvim-treesitter-textobjects")
    if okto then
      require("nvim-treesitter-textobjects").setup({
        select = { lookahead = true },
        move = { set_jumps = true },
      })
      local sel = require("nvim-treesitter-textobjects.select").select_textobject
      local move = require("nvim-treesitter-textobjects.move")
      local swap = require("nvim-treesitter-textobjects.swap")
      local map = vim.keymap.set

      local objects = {
        ["af"] = "@function.outer", ["if"] = "@function.inner",
        ["ac"] = "@class.outer", ["ic"] = "@class.inner",
        ["aa"] = "@parameter.outer", ["ia"] = "@parameter.inner",
      }
      for lhs, q in pairs(objects) do
        map({ "x", "o" }, lhs, function() sel(q, "textobjects") end, { desc = "TS " .. q })
      end

      map({ "n", "x", "o" }, "]m", function() move.goto_next_start("@function.outer", "textobjects") end, { desc = "Next function" })
      map({ "n", "x", "o" }, "[m", function() move.goto_previous_start("@function.outer", "textobjects") end, { desc = "Prev function" })
      map({ "n", "x", "o" }, "]]", function() move.goto_next_start("@class.outer", "textobjects") end, { desc = "Next class" })
      map({ "n", "x", "o" }, "[[", function() move.goto_previous_start("@class.outer", "textobjects") end, { desc = "Prev class" })

      map("n", "<leader>na", function() swap.swap_next("@parameter.inner") end, { desc = "Swap arg next" })
      map("n", "<leader>pa", function() swap.swap_previous("@parameter.inner") end, { desc = "Swap arg prev" })
    end
  end,
}
