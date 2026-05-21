return {
  "ravitemer/mcphub.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  build = "npm install -g --prefix ~/.local mcp-hub@latest",
  config = function()
    require("mcphub").setup({
      config = vim.fn.expand("~/.config/mcphub/servers.json"),
      cmd = vim.fn.expand("~/.local/bin/mcp-hub"),
    })
  end,
}
