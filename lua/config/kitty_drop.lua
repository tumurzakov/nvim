-- kitty_drop: send text from nvim into another kitty window (the Claude Code TUI
-- in a separate tab) via kitty's remote-control socket.
--
-- Requires kitty started with `allow_remote_control yes` + `listen_on unix:...`
-- (so KITTY_LISTEN_ON is set). The destination is the window whose window-title
-- OR tab-title contains the marker `[kd]` — set that title yourself on the tab you
-- want drops to land in. Change the marker or pin a full kitty --match expression
-- via settings_local `kitty_drop.marker` / `kitty_drop.match`.
local M = {}

local function cfg()
  local ok, sl = pcall(require, "config.settings_local")
  return (ok and type(sl) == "table" and sl.kitty_drop) or {}
end

local function marker()
  return cfg().marker or "[kd]"
end

local function socket()
  return os.getenv("KITTY_LISTEN_ON")
end

-- Resolve the destination window id by scanning window/tab titles for the marker
-- (plain substring), excluding nvim's own window. Returns id, title or nil.
local function resolve(sock, self_id)
  local res = vim.system({ "kitty", "@", "--to", sock, "ls" }, { text = true }):wait()
  if res.code ~= 0 then return nil end
  local ok, data = pcall(vim.json.decode, res.stdout)
  if not ok or type(data) ~= "table" then return nil end

  local mk = marker()
  for _, osw in ipairs(data) do
    for _, t in ipairs(osw.tabs or {}) do
      local tab_has = (t.title or ""):find(mk, 1, true) ~= nil
      for _, w in ipairs(t.windows or {}) do
        if tostring(w.id) ~= tostring(self_id)
          and (tab_has or (w.title or ""):find(mk, 1, true) ~= nil) then
          return w.id, (w.title ~= "" and w.title) or t.title
        end
      end
    end
  end
  return nil
end

-- Send raw text to the resolved Claude window. opts.submit = true appends Enter.
function M.send(text, opts)
  opts = opts or {}
  local sock = socket()
  if not sock or sock == "" then
    vim.notify("kitty_drop: KITTY_LISTEN_ON not set — enable remote control in kitty.conf and restart kitty",
      vim.log.levels.WARN)
    return
  end
  if not text or text == "" then return end

  local override = cfg().match
  local matcher, dest
  if override and override ~= "" then
    matcher = override
  else
    local id, title = resolve(sock, os.getenv("KITTY_WINDOW_ID"))
    if not id then
      vim.notify("kitty_drop: no window titled with '" .. marker() ..
        "' — set that marker in the target tab/window title", vim.log.levels.WARN)
      return
    end
    matcher, dest = "id:" .. id, title
  end

  if opts.submit then text = text .. "\r" end
  local cmd = { "kitty", "@", "--to", sock, "send-text",
    "--match", matcher, "--stdin", "--bracketed-paste=auto" }
  vim.system(cmd, { stdin = text }, vim.schedule_wrap(function(res)
    if res.code ~= 0 then
      vim.notify("kitty_drop: send failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
    else
      vim.notify("kitty_drop: sent → " .. (dest or matcher), vim.log.levels.INFO)
    end
  end))
end

-- The review_view module (gR), if loaded — used to translate diff-buffer
-- selections back to real file paths and source line numbers.
local function review_view()
  local ok, m = pcall(require, "config.review_view")
  return ok and m or nil
end

-- A "repo `x`, reviewing `base → head`" prefix when the drop comes from a gR
-- review buffer, so the Claude side knows which repo and branches it is.
local function review_header(ctx)
  if ctx and ctx.repo and ctx.base and ctx.head then
    return ("repo `%s`, reviewing `%s → %s`"):format(ctx.repo, ctx.base, ctx.head)
  end
  return nil
end

-- Repo-relative path for a buffer: its real filename, or — for a gR diff scratch
-- buffer — the file that diff belongs to.
local function relpath(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name ~= "" then return vim.fn.fnamemodify(name, ":.") end
  local rv = review_view()
  return rv and rv.file_for and rv.file_for(bufnr) or nil
end

-- Send the current file's path (e.g. to @-reference it in the Claude prompt).
function M.send_path()
  local p = relpath()
  if not p then vim.notify("kitty_drop: no file in this buffer", vim.log.levels.WARN); return end
  M.send(p)
end

-- Send a `path:line` reference for the cursor position (source line if in a
-- gR diff buffer).
function M.send_lineref()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local rv = review_view()
  local ctx = rv and rv.context_for and rv.context_for(buf, row, row) or nil
  if ctx then
    local hdr = review_header(ctx)
    if hdr then
      M.send(("%s — `%s:%d`"):format(hdr, ctx.file, ctx.l1 or row))
    else
      M.send(("`%s:%d`"):format(ctx.file, ctx.l1 or row))
    end
    return
  end
  local p = relpath(buf)
  if not p then vim.notify("kitty_drop: no file in this buffer", vim.log.levels.WARN); return end
  M.send(("`%s:%d`"):format(p, row))
end

-- Send the visual selection with full context. In a gR diff buffer this resolves
-- the real file + source line range and sends the selected hunk as ```diff; on a
-- normal file it sends the code with a `path:Lstart-Lend` header.
function M.send_visual()
  local l1 = vim.fn.getpos("'<")[2]
  local l2 = vim.fn.getpos("'>")[2]
  if l1 == 0 or l2 == 0 then
    vim.notify("kitty_drop: no visual selection found", vim.log.levels.WARN); return
  end
  if l1 > l2 then l1, l2 = l2, l1 end
  local buf = vim.api.nvim_get_current_buf()

  local rv = review_view()
  local ctx = rv and rv.context_for and rv.context_for(buf, l1, l2) or nil
  local file, lines, ft, lo, hi
  if ctx then
    -- selection in a gR review buffer → real file path + source line range
    file, lines, ft = ctx.file, ctx.lines, (ctx.ft ~= "" and ctx.ft or "")
    lo, hi = ctx.l1 or l1, ctx.l2 or l2
  else
    file = relpath(buf) or "selection"
    lines = vim.api.nvim_buf_get_lines(buf, l1 - 1, l2, false)
    ft = vim.bo.filetype ~= "" and vim.bo.filetype or ""
    lo, hi = l1, l2
  end
  local parts = {}
  local hdr = review_header(ctx)
  if hdr then table.insert(parts, hdr) end
  vim.list_extend(parts, {
    ("In `%s` (lines %d-%d):"):format(file, lo, hi),
    "```" .. ft, table.concat(lines, "\n"), "```", "",
  })
  M.send(table.concat(parts, "\n"))
end

return M
