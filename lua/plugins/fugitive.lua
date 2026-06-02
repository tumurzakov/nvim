return {
  {
    "tpope/vim-fugitive",
  },
  {
    "lewis6991/gitsigns.nvim",
    config = function()
      require("gitsigns").setup({})
    end,
  },
  {
    "sindrets/diffview.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    cmd = { "DiffviewOpen", "DiffviewFileHistory", "DiffviewClose" },
    keys = {
      { "<leader>gd", "<cmd>DiffviewOpen<cr>", desc = "Diffview: all changes" },
      { "<leader>gh", "<cmd>DiffviewFileHistory %<cr>", desc = "Diffview: file history" },
      { "<leader>gH", "<cmd>DiffviewFileHistory<cr>", desc = "Diffview: branch history" },
      { "<leader>gc", "<cmd>DiffviewClose<cr>", desc = "Diffview: close" },
    },
    opts = {
      enhanced_diff_hl = true,
      default_args = { DiffviewFileHistory = {} },
      view = {
        default = { layout = "diff2_horizontal" },
        merge_tool = { layout = "diff3_mixed" },
      },
      file_panel = {
        listing_style = "tree",
        win_config = { width = 35 },
      },
      file_history_panel = {
        log_options = {
          git = {
            single_file = { follow = false },
            multi_file = {},
          },
        },
      },
    },
  },
}
