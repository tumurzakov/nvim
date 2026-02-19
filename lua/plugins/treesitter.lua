return {
  "nvim-treesitter/nvim-treesitter",
  lazy = false,
  build = ":TSUpdate",
  config = function()
    local ok, ts = pcall(require, "nvim-treesitter")
    if not ok then
      vim.notify("nvim-treesitter is not available", vim.log.levels.WARN)
      return
    end

    ts.setup({})

    -- Needed by CodeCompanion markdown prompt library parser.
    pcall(function()
      ts.install({ "lua", "python", "yaml", "markdown", "markdown_inline", "vim", "vimdoc", "query" })
    end)
  end,
}
