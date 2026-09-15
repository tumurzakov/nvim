-- Live preview via a local HTTP server (scripts/md_server.py).
--
-- The server serves a whole directory tree over http://127.0.0.1:6419/ ; markdown
-- is rendered and auto-reloads on save, other files are served raw. Localhost only.
--
-- The server is DETACHED: it keeps serving after the nvim that spawned it exits,
-- so closing the buffer you previewed — or the whole editor — leaves the page in
-- your browser working. `<leader>ms` is what stops it.
--
-- That makes one server shared by every nvim on the machine, so it can't be
-- tracked by a job handle. A 0600 state file records the port and a control
-- token, and the server answers /__ctl/<token>/{info,reroot,quit} — which is how
-- a later nvim finds the running server, re-roots it, or shuts it down.
--
-- The served root follows the file you preview: on <leader>mm the server is
-- re-rooted at the current file's git repo (or its parent dir when not in a
-- repo), so previewing a file in a sibling project just works instead of being
-- refused as "outside the served root".
local M = {}

local PORT = 6419
local HOST = "127.0.0.1"
local STATE_FILE = vim.fn.stdpath("state") .. "/md_server.json"
local LOG_FILE = vim.fn.stdpath("state") .. "/md_server.log"
local uv = vim.uv or vim.loop

-- Cache of what we know about the running server. `token` and `root` may equally
-- well come from the state file: the server may predate this nvim.
local state = { job = nil, token = nil, root = nil }

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

local function read_state()
  local f = io.open(STATE_FILE, "r")
  if not f then return nil end
  local txt = f:read("*a")
  f:close()
  local ok, t = pcall(vim.json.decode, txt)
  return (ok and type(t) == "table") and t or nil
end

local function write_state(t)
  local f = io.open(STATE_FILE, "w")
  if not f then return end
  f:write(vim.json.encode(t))
  f:close()
  pcall(uv.fs_chmod, STATE_FILE, tonumber("600", 8))  -- the token is a capability
end

-- A control token: 16 random bytes, hex. Only has to be unguessable by a web page
-- that knows the port — it never leaves this machine.
local function new_token()
  local f = io.open("/dev/urandom", "rb")
  local bytes = f and f:read(16)
  if f then f:close() end
  if bytes and #bytes == 16 then
    return (bytes:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
  end
  math.randomseed(os.time() + uv.hrtime() % 1000000)
  local out = {}
  for i = 1, 32 do out[i] = string.format("%x", math.random(0, 15)) end
  return table.concat(out)
end

-- Call a control endpoint on the running server. Returns its decoded JSON reply,
-- or nil when nothing answers — no server, or a state file left behind by one
-- that has since died.
local function ctl(action, query)
  local token = state.token or (read_state() or {}).token
  if not token or vim.fn.executable("curl") == 0 then return nil end
  local url = ("http://%s:%d/__ctl/%s/%s"):format(HOST, PORT, token, action)
  if query then url = url .. "?" .. query end
  local out = vim.fn.systemlist({ "curl", "-sf", "--max-time", "2", url })
  if vim.v.shell_error ~= 0 then return nil end
  local ok, t = pcall(vim.json.decode, table.concat(out, "\n"))
  return (ok and type(t) == "table") and t or nil
end

-- Poll until the server stops answering (it is shutting down) or starts (it has
-- bound the port). Returns the last /info reply, or nil.
local function wait_for(want_up)
  for _ = 1, 40 do                 -- 2s; a refused connect fails immediately
    local info = ctl("info")
    if (info ~= nil) == want_up then return info end
    vim.wait(50)
  end
  return ctl("info")
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

-- Make the server serve `root` (default: nvim's cwd), starting it if need be.
-- A server that is already up is re-rooted in place rather than restarted, so
-- pages open on it survive.
--
-- Started on demand from M.open() and never from startup: the server outlives
-- every nvim now, so autostarting it would leave a localhost server on your cwd
-- running forever after any nvim launch, whether or not you ever previewed.
function M.start(root)
  root = (root or vim.fn.getcwd()):gsub("/+$", "")

  local info = ctl("info")
  if info then
    if info.root == root then
      state.token = state.token or (read_state() or {}).token
      state.root = info.root
      return true
    end
    local rerooted = ctl("reroot", "path=" .. url_encode_path(root))
    if rerooted and rerooted.root then
      state.root = rerooted.root
      return true
    end
    M.stop()  -- up but won't re-root (older build?): replace it
  end

  if vim.fn.filereadable(script_path()) == 0 then
    vim.notify("[md] server script missing: " .. script_path(), vim.log.levels.ERROR)
    return false
  end

  local token = new_token()
  write_state({ port = PORT, token = token, root = root })
  state.token, state.root = token, root

  -- Detached, with output appended to a log file: once nvim exits there is no
  -- pipe left, and a traceback written into a closed one would kill the server.
  local cmd = ("exec %s %s --root %s --host %s --port %d --token %s >>%s 2>&1"):format(
    vim.fn.shellescape(python()), vim.fn.shellescape(script_path()),
    vim.fn.shellescape(root), HOST, PORT, token, vim.fn.shellescape(LOG_FILE))
  local job = vim.fn.jobstart({ "sh", "-c", cmd }, { detach = true })
  if not job or job <= 0 then
    vim.notify("[md] failed to start server", vim.log.levels.ERROR)
    return false
  end
  state.job = job

  local up = wait_for(true)
  if not up then
    vim.notify("[md] server did not come up — see " .. LOG_FILE, vim.log.levels.ERROR)
    return false
  end
  state.root = up.root
  return true
end

-- Stop the server, whichever nvim started it — the control endpoint makes it shut
-- itself down, so one left over from an earlier session stops too.
function M.stop()
  local running = ctl("info") ~= nil
  if running then
    ctl("quit")
    wait_for(false)  -- block until the port is free, so a restart can rebind it
  end
  if state.job then pcall(vim.fn.jobstop, state.job) end
  state.job, state.token, state.root = nil, nil, nil
  os.remove(STATE_FILE)
  if running then vim.notify("[md] server stopped", vim.log.levels.INFO) end
  return running
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
    if file == root then
      -- root index; leave url as "/"
    elseif vim.startswith(file, root .. "/") then
      url = url .. url_encode_path(file:sub(#root + 2))
    else
      vim.notify("[md] file is outside the served root:\n  " .. root,
        vim.log.levels.WARN)
    end
  end

  open_browser(url)
  vim.notify("[md] " .. url .. "   (keeps serving after nvim exits; \\ms stops it)",
    vim.log.levels.INFO)
end

return M
