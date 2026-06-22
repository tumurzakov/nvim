-- Live preview via a local HTTP server (scripts/md_server.py).
--
-- The server is started once on nvim launch and serves the whole directory tree
-- rooted at the folder nvim was started in (cwd). Every file is reachable by its
-- path under http://127.0.0.1:6419/ ; markdown is rendered and auto-reloads on
-- save, other files are served raw. Localhost only. The server is a child of
-- nvim, so it dies when nvim exits.
local M = {}

local PORT = 6419
local HOST = "127.0.0.1"
local state = { job = nil, root = nil }

local function script_path()
  return vim.fn.stdpath("config") .. "/scripts/md_server.py"
end

local function python()
  return vim.fn.executable("python3") == 1 and "python3" or "python"
end

local function open_browser(url)
  if vim.ui and vim.ui.open then
    vim.ui.open(url)
  else
    vim.system({ "open", url })
  end
end

-- Percent-encode a relative path for use in a URL, preserving "/" separators.
local function url_encode_path(rel)
  return (rel:gsub("[^%w%-%._~/]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

-- Start the server rooted at nvim's current working directory (idempotent).
function M.start()
  if state.job then return true end

  if vim.fn.filereadable(script_path()) == 0 then
    vim.notify("[md] server script missing: " .. script_path(), vim.log.levels.ERROR)
    return false
  end

  local root = vim.fn.getcwd()
  local cmd = { python(), script_path(), "--root", root, "--host", HOST, "--port", tostring(PORT) }
  local job = vim.fn.jobstart(cmd, {
    on_exit = function(_, code)
      state.job = nil
      state.root = nil
      if code ~= 0 and code ~= 143 then -- 143 = SIGTERM from our stop()
        vim.schedule(function()
          vim.notify("[md] server exited (code " .. code .. ")", vim.log.levels.WARN)
        end)
      end
    end,
  })

  if not job or job <= 0 then
    vim.notify("[md] failed to start server", vim.log.levels.ERROR)
    return false
  end

  state.job = job
  state.root = root
  return true
end

function M.stop()
  if state.job then
    pcall(vim.fn.jobstop, state.job)
    state.job = nil
    state.root = nil
  end
end

-- Open the browser at the URL for the current buffer's file (relative to root).
-- Falls back to the root listing if the buffer has no on-disk file or it lives
-- outside the served root.
function M.open()
  if not M.start() then return end

  local url = string.format("http://%s:%d/", HOST, PORT)
  local file = vim.fn.expand("%:p")
  if file ~= "" and state.root then
    local rel = vim.fn.fnamemodify(file, ":.")
    -- ":." is relative to cwd; if the file is under root it won't be absolute.
    if not rel:match("^/") and rel ~= "" then
      url = url .. url_encode_path(rel)
    end
  end

  open_browser(url)
  vim.notify("[md] " .. url, vim.log.levels.INFO)
end

function M.setup()
  vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = function() M.start() end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function() M.stop() end,
  })
end

return M
