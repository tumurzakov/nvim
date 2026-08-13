-- Live preview via a local HTTP server (scripts/md_server.py).
--
-- The server serves a whole directory tree over http://127.0.0.1:6419/ ; markdown
-- is rendered and auto-reloads on save, other files are served raw. Localhost only.
-- The server is a child of nvim, so it dies when nvim exits.
--
-- The served root follows the file you preview: on <leader>mm the server is
-- (re)rooted at the current file's git repo (or its parent dir when not in a
-- repo), so previewing a file in a sibling project just works instead of being
-- refused as "outside the served root".
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

-- The directory the server should be rooted at to reach `file`: its git repo
-- top-level (so intra-repo links/images resolve), else the file's parent dir.
local function root_for(file)
  local dir = vim.fn.fnamemodify(file, ":h")
  local out = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error == 0 and out[1] and out[1] ~= "" then
    return (out[1]:gsub("/+$", ""))
  end
  return (dir:gsub("/+$", ""))
end

-- Start the server rooted at `root` (default: nvim's cwd). Idempotent when the
-- server is already running at the same root; re-roots (restart) otherwise.
function M.start(root)
  root = (root or vim.fn.getcwd()):gsub("/+$", "")

  if state.job then
    if state.root == root then return true end
    M.stop() -- root changed: restart so the new tree is served
  end

  if vim.fn.filereadable(script_path()) == 0 then
    vim.notify("[md] server script missing: " .. script_path(), vim.log.levels.ERROR)
    return false
  end

  local cmd = { python(), script_path(), "--root", root, "--host", HOST, "--port", tostring(PORT) }
  local job = vim.fn.jobstart(cmd, {
    on_exit = function(id, code)
      -- Only clear state if this is still the live job: on re-root the old
      -- server's on_exit fires after the new one is recorded, and must not
      -- clobber it.
      if state.job == id then
        state.job = nil
        state.root = nil
      end
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
  local job = state.job
  if job then
    -- Clear state first so the async on_exit (id ~= state.job now) is a no-op,
    -- then block until the process is gone so port 6419 is released before any
    -- restart rebinds it — otherwise the new server fails to bind and dies.
    state.job = nil
    state.root = nil
    pcall(vim.fn.jobstop, job)
    pcall(vim.fn.jobwait, { job }, 2000)
  end
end

-- Open the browser at the URL for the current buffer's file (relative to root).
-- Falls back to the root listing if the buffer has no on-disk file or it lives
-- outside the served root.
function M.open()
  local file = vim.fn.expand("%:p")

  -- gR review diff panes are `nofile` buffers named with a virtual `review://`
  -- scheme, not real files — resolve them back to the actual file on disk so the
  -- preview has something to serve.
  if file:match("^review://") or vim.bo.buftype == "nofile" then
    local ok, rv = pcall(require, "config.review_view")
    local real = ok and rv.real_path_for(vim.api.nvim_get_current_buf())
    if real and real ~= "" then file = real end
  end

  -- Root the server at the current file's repo so previewing files in sibling
  -- projects works; re-roots the running server when you cross into another repo.
  if not M.start(file ~= "" and vim.fn.filereadable(file) == 1 and root_for(file) or nil) then return end

  local url = string.format("http://%s:%d/", HOST, PORT)
  local root = state.root and state.root:gsub("/+$", "")
  if file ~= "" and root then
    -- The path MUST be relative to the server root (nvim's startup cwd), not the
    -- current cwd — nvim-tree / :cd can move cwd and drop path segments, which
    -- produced a wrong URL and a "Not found".
    if file == root then
      -- root index; leave url as "/"
    elseif vim.startswith(file, root .. "/") then
      url = url .. url_encode_path(file:sub(#root + 2))
    else
      vim.notify("[md] file is outside the served root:\n  " .. root
        .. "\n(server was rooted at nvim's startup dir; :cd there or restart nvim)",
        vim.log.levels.WARN)
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
