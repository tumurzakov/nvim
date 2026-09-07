return {
  "stevearc/aerial.nvim",
  -- master requires Neovim 0.12: on anything older its plugin file aborts with
  -- "aerial is deprecated for Neovim <0.12" BEFORE creating :Aerial*, so lazy's
  -- cmd trigger loads it and then fails with "Command `AerialToggle` not found".
  -- Track the branch matching the Neovim we run instead.
  branch = "nvim-0.11",
  cmd = {
    "AerialToggle",
    "AerialOpen",
    "AerialClose",
    "AerialNavToggle",
    "AerialNext",
    "AerialPrev",
  },
  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    "nvim-tree/nvim-web-devicons",
  },
  opts = {},
}
