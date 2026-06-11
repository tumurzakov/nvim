-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git", "clone", "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

-- Load core settings and mappings first
require("config.options")
require("config.keybindings")

-- Load all plugin specs from lua/plugins/*
require("lazy").setup("plugins")

-- Startup cheatsheet (shown when no files given)
require("config.help").setup()

-- :Agenda command
require("config.agenda").setup()

-- Voice dictation (Vosk)
require("config.dictation")

require("config.diff_review")
