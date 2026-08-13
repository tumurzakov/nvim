-- kitty_drop: send text from nvim into another kitty window (the Claude Code TUI
-- in a separate tab) via kitty's remote-control socket.
--
-- Requires kitty started with `allow_remote_control yes` + `listen_on unix:...`
-- (so KITTY_LISTEN_ON is set). The first drop asks which kitty window to send to
-- and remembers it; later drops reuse that window on a single Enter (press `n` at
-- the prompt to pick a different one). Pin a fixed kitty --match expression via
-- settings_local `kitty_drop.match` to skip the prompt entirely.
local M = {}

local function cfg()
  local ok, sl = pcall(require, "config.settings_local")
  return (ok and type(sl) == "table" and sl.kitty_drop) or {}
end

local function socket()
  return os.getenv("KITTY_LISTEN_ON")
end

-- Persisted destination (survives restarts). We store title/cwd hints rather than
-- the raw window id, since kitty window ids are reassigned across sessions.
local function state_path()
  return vim.fn.stdpath("state") .. "/kitty_drop_dest.json"
end

local function load_saved()
  local f = io.open(state_path(), "r")
  if not f then return nil end
  local raw = f:read("*a"); f:close()
  local ok, d = pcall(vim.json.decode, raw)
  return (ok and type(d) == "table") and d or nil
end

local function save_dest(d)
  local f = io.open(state_path(), "w")
  if not f then return end
  f:write(vim.json.encode(d)); f:close()
end

-- Forget the remembered destination; the next drop will ask again.
function M.forget()
  os.remove(state_path())
  vim.notify("kitty_drop: forgot saved destination", vim.log.levels.INFO)
end

-- List candidate windows (everything except nvim's own), newest kitty `ls` order.
local function list_windows(sock, self_id)
  local res = vim.system({ "kitty", "@", "--to", sock, "ls" }, { text = true }):wait()
  if res.code ~= 0 then return {} end
  local ok, data = pcall(vim.json.decode, res.stdout)
  if not ok or type(data) ~= "table" then return {} end
  local out = {}
  for _, osw in ipairs(data) do
    for _, t in ipairs(osw.tabs or {}) do
      for _, w in ipairs(t.windows or {}) do
        if tostring(w.id) ~= tostring(self_id) then
          out[#out + 1] = {
            id = w.id,
            tab_title = t.title or "",
            win_title = w.title or "",
            cwd = w.cwd or "",
            label = ("%s › %s"):format(t.title or "?",
              (w.title ~= "" and w.title) or ("win " .. w.id)),
          }
        end
      end
    end
  end
  return out
end

-- A candidate matches the saved destination if any stable hint lines up.
local function matches(c, saved)
  if not saved then return false end
  return (saved.tab_title and saved.tab_title ~= "" and c.tab_title == saved.tab_title)
    or (saved.win_title and saved.win_title ~= "" and c.win_title == saved.win_title)
    or (saved.cwd and saved.cwd ~= "" and c.cwd == saved.cwd)
end

local function remember(c)
  save_dest({ tab_title = c.tab_title, win_title = c.win_title, cwd = c.cwd, label = c.label })
end

-- Resolve the destination asynchronously and call cb(matcher, label) — or cb(nil)
-- if cancelled. A pinned settings_local match skips the prompt; otherwise we reuse
-- the saved window (single Enter) or pick a new one the first time / on demand.
local function resolve_dest(sock, cb)
  local override = cfg().match
  if override and override ~= "" then cb(override, override); return end

  local cands = list_windows(sock, os.getenv("KITTY_WINDOW_ID"))
  if #cands == 0 then
    vim.notify("kitty_drop: no other kitty windows to send to", vim.log.levels.WARN)
    cb(nil); return
  end

  local function full_pick()
    vim.ui.select(cands, {
      prompt = "kitty_drop: send to which window?",
      format_item = function(c) return c.label end,
    }, function(c)
      if not c then cb(nil); return end
      remember(c)
      cb("id:" .. c.id, c.label)
    end)
  end

  local saved = load_saved()
  local savedCand
  for _, c in ipairs(cands) do
    if matches(c, saved) then savedCand = c; break end
  end

  if savedCand then
    vim.ui.input({
      prompt = ("kitty_drop → '%s'?  [Enter=send, n=pick other] "):format(savedCand.label),
    }, function(ans)
      if ans == nil then cb(nil); return end -- Esc: cancel
      ans = ans:lower()
      if ans == "" or ans == "y" then
        remember(savedCand) -- refresh label/hints in case they drifted
        cb("id:" .. savedCand.id, savedCand.label)
      else
        full_pick()
      end
    end)
  else
    full_pick()
  end
end

-- Send raw text to the chosen kitty window. opts.submit = true appends Enter.
function M.send(text, opts)
  opts = opts or {}
  local sock = socket()
  if not sock or sock == "" then
    vim.notify("kitty_drop: KITTY_LISTEN_ON not set — enable remote control in kitty.conf and restart kitty",
      vim.log.levels.WARN)
    return
  end
  if not text or text == "" then return end

  resolve_dest(sock, function(matcher, dest)
    if not matcher then return end
    local payload = opts.submit and (text .. "\r") or text
    local cmd = { "kitty", "@", "--to", sock, "send-text",
      "--match", matcher, "--stdin", "--bracketed-paste=auto" }
    vim.system(cmd, { stdin = payload }, vim.schedule_wrap(function(res)
      if res.code ~= 0 then
        vim.notify("kitty_drop: send failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
      else
        vim.notify("kitty_drop: sent → " .. (dest or matcher), vim.log.levels.INFO)
      end
    end))
  end)
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
