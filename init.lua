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

-- Startup greeting: keybindings + recent project files
vim.api.nvim_create_autocmd("VimEnter", {
  group = vim.api.nvim_create_augroup("user.startup", { clear = true }),
  once = true,
  callback = function()
    -- Skip if opened with files or stdin
    if vim.fn.argc() > 0 or vim.bo.filetype ~= "" then
      return
    end

    local cwd = vim.fn.getcwd()
    local recent = {}
    for _, f in ipairs(vim.v.oldfiles or {}) do
      if #recent >= 3 then break end
      if vim.startswith(f, cwd .. "/") and vim.fn.filereadable(f) == 1 then
        table.insert(recent, f:sub(#cwd + 2))
      end
    end

    local lines = {
      "",
      "  Keybindings:",
      "  \\tt  File tree        \\ff  Find files      \\fg  Live grep",
      "  \\cc  CodeCompanion    C-l  Chat+selection   \\ci  Rewrite selection",
      "  \\r   Terminal split   \\rv  Terminal vsplit  C-b c  Terminal tab",
      "  \\ta  Pytest all       \\tf  Pytest file      \\tn  Pytest nearest",
      "  \\x   Run Python       \\rx  Ruff fix         \\f   Format (LSP)",
      "",
    }

    if #recent > 0 then
      table.insert(lines, "  Recent files (project):")
      for i, f in ipairs(recent) do
        table.insert(lines, "  " .. i .. ". " .. f)
      end
      table.insert(lines, "")
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false
    vim.api.nvim_set_current_buf(buf)

    -- Press Enter or q to dismiss
    local function dismiss()
      if vim.api.nvim_buf_is_valid(buf) then
        vim.cmd("enew")
      end
    end
    vim.keymap.set("n", "<CR>", dismiss, { buffer = buf, nowait = true })
    vim.keymap.set("n", "q", dismiss, { buffer = buf, nowait = true })

    -- Open recent file by number
    for i, f in ipairs(recent) do
      vim.keymap.set("n", tostring(i), function()
        vim.cmd("edit " .. vim.fn.fnameescape(cwd .. "/" .. f))
      end, { buffer = buf, nowait = true })
    end
  end,
})
