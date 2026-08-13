-- :ReloadConfig — purge config.* modules, re-run options + keybindings, and
-- reload the lazy.nvim plugin specs.
local M = {}

function M.reload()
  if vim.g.__nvim_config_reloading then
    vim.notify("Reload already in progress", vim.log.levels.WARN)
    return
  end

  vim.g.__nvim_config_reloading = true

  vim.schedule(function()
    local errors = {}
    local reloaded_plugins = 0

    local function run_step(fn)
      local ok, err = pcall(fn)
      if not ok then
        table.insert(errors, tostring(err))
      end
    end

    run_step(function()
      for module, _ in pairs(package.loaded) do
        if module:match("^config%.") then
          package.loaded[module] = nil
        end
      end
      require("config.options")
      require("config.keybindings")
    end)

    run_step(function()
      local ok_plugin, plugin = pcall(require, "lazy.core.plugin")
      if not ok_plugin then
        return
      end

      plugin.load()
      reloaded_plugins = vim.tbl_count(require("lazy.core.config").plugins or {})
      pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "LazyReload", modeline = false })
    end)

    vim.g.__nvim_config_reloading = false

    if #errors > 0 then
      vim.notify("Config reload failed:\n" .. table.concat(errors, "\n"), vim.log.levels.ERROR)
      return
    end

    vim.notify(string.format("Neovim config reloaded (%d plugins)", reloaded_plugins), vim.log.levels.INFO)
  end)
end

pcall(vim.api.nvim_del_user_command, "ReloadConfig")
vim.api.nvim_create_user_command("ReloadConfig", M.reload, {
  desc = "Reload Neovim config and Lazy specs",
})

return M
