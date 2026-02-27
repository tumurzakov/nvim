return {
  "ahmedkhalf/project.nvim",
  dependencies = {
    "nvim-telescope/telescope.nvim",
  },
  opts = {
    detection_methods = { "pattern" },
    patterns = { ".git" },
    silent_chdir = true,
    scope_chdir = "global",
  },
  config = function(_, opts)
    require("project_nvim").setup(opts)
    pcall(function()
      require("telescope").load_extension("projects")
    end)
  end,
}
