return {
  "folke/trouble.nvim",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  cmd = "Trouble",
  keys = {
    { "<leader>xx", "<cmd>Trouble diagnostics toggle<cr>",                        desc = "Trouble: workspace diagnostics" },
    { "<leader>xX", "<cmd>Trouble diagnostics toggle filter.buf=0<cr>",           desc = "Trouble: buffer diagnostics" },
    { "<leader>xL", "<cmd>Trouble loclist toggle<cr>",                            desc = "Trouble: location list" },
    { "<leader>xQ", "<cmd>Trouble qflist toggle<cr>",                             desc = "Trouble: quickfix list" },
    { "<leader>xs", "<cmd>Trouble symbols toggle focus=false<cr>",                desc = "Trouble: symbols" },
    { "<leader>xl", "<cmd>Trouble lsp toggle focus=false win.position=right<cr>", desc = "Trouble: LSP definitions / references" },
    { "[x",         function() require("trouble").prev({ skip_groups = true, jump = true }) end, desc = "Trouble: prev item" },
    { "]x",         function() require("trouble").next({ skip_groups = true, jump = true }) end, desc = "Trouble: next item" },
  },
  opts = {},
}
