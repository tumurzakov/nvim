return {
  "hrsh7th/nvim-cmp",
  dependencies = {
    "hrsh7th/cmp-nvim-lsp",
  },
  config = function()
    local cmp = require("cmp")

    vim.o.completeopt = "menu,menuone,noselect"

    cmp.setup({
      snippet = {
        expand = function(_) end,
      },
      mapping = cmp.mapping.preset.insert({
        ["<C-Space>"] = cmp.mapping.complete(),
        ["<CR>"] = cmp.mapping.confirm({ select = false }),
        ["<C-e>"] = cmp.mapping.abort(),
      }),
      sources = {
        { name = "nvim_lsp" },
      },
    })
  end,
}
