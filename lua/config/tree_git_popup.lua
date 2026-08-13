-- Floating git info popup for nvim-tree: when the cursor lands on a folder that
-- lives in a git repo, show a small float to the RIGHT of the tree window (never
-- overlapping the file list) with the branch, ahead/behind vs upstream, and the
-- uncommitted-file breakdown *for that folder* (pathspec-limited, so hovering a
-- subfolder counts only its changes).
--
-- The cheap info (status + last commit) runs automatically, debounced, async via
-- vim.system. Distance from origin's default branch (e.g. origin/main) is an
-- extra git call left off the hot path — press the `gf` mapping over a folder to
-- add it. The float is non-focusable and closes when the cursor leaves a repo
-- folder or the tree window.
local M = {}

local NERD = (function()
  local ok, sl = pcall(require, "config.settings_local")
  return not (ok and type(sl) == "table" and sl.nerd_font_icons == false)
end)()

local ICON = NERD
    and { branch = " ", ahead = "↑", behind = "↓", staged = "✚", mod = "●", untrk = "?", clean = "✓", base = "⇅ ", term = " " }
    or { branch = "", ahead = "+", behind = "-", staged = "S", mod = "M", untrk = "?", clean = "ok", base = "vs ", term = "$ " }

-- Dimmed footer reminding of the folder actions. `\` is the leader, so `\T` is
-- the focus-terminal mapping; `gf` fetches origin then shows branch distance.
local HINTS = "T term   \\T term+focus   gf fetch+dist   gp pull"

local win, buf
local NS = vim.api.nvim_create_namespace("tree_git_popup")
local timer = (vim.uv or vim.loop).new_timer()
local seq = 0   -- bumped on every cursor move; guards stale async results

-- Everything the popup currently reflects. Rebuilt as async pieces arrive.
local state = { dir = nil, treewin = nil, summary = nil, subject = nil, distance = nil }

local function remote_name()
  local ok, sl = pcall(require, "config.settings_local")
  return (ok and type(sl) == "table" and sl.git_remote) or "origin"
end

local function base_branch()
  local ok, sl = pcall(require, "config.settings_local")
  return (ok and type(sl) == "table" and sl.git_base_branch) or "main"
end

function M.close()
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  win = nil
  state.dir, state.summary, state.subject, state.distance = nil, nil, nil, nil
end

-- Place `lines` in a float anchored just right of the tree window, aligned to
-- the cursor row. Falls back to a cursor-relative float if the tree win is gone.
local function show(lines)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, h in ipairs(state._hls or {}) do
    vim.api.nvim_buf_set_extmark(buf, NS, h[1], 0, { end_row = h[1] + 1, hl_group = h[2], hl_eol = true })
  end
  local width = 1
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l)) end

  local cfg = {
    anchor = "NW", width = width + 1, height = #lines,
    style = "minimal", border = "rounded", focusable = false,
  }
  local tw = state.treewin
  if tw and vim.api.nvim_win_is_valid(tw) then
    cfg.relative = "win"
    cfg.win = tw
    cfg.row = vim.api.nvim_win_call(tw, vim.fn.winline) - 1
    cfg.col = vim.api.nvim_win_get_width(tw) + 1
  else
    cfg.relative = "cursor"
    cfg.row, cfg.col = 1, 2
  end

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_config(win, cfg)   -- NB: no `noautocmd` on existing windows
  else
    cfg.noautocmd = true
    win = vim.api.nvim_open_win(buf, false, cfg)
    vim.wo[win].winhl = "Normal:NormalFloat,FloatBorder:FloatBorder"
  end
end

-- Parse `git status --porcelain=v1 --branch -- .` into a summary table.
local function parse(out)
  local s = { branch = nil, ahead = 0, behind = 0, staged = 0, modified = 0, untracked = 0, total = 0 }
  for _, l in ipairs(vim.split(out, "\n", { trimempty = true })) do
    if l:sub(1, 2) == "##" then
      local b = l:sub(4)
      if b:match("^HEAD %(no branch%)") then
        s.branch = "(detached)"
      else
        s.branch = b:match("^([^%.%s]+)")
        s.ahead = tonumber(b:match("ahead (%d+)")) or 0
        s.behind = tonumber(b:match("behind (%d+)")) or 0
      end
    else
      s.total = s.total + 1
      if l:sub(1, 2) == "??" then
        s.untracked = s.untracked + 1
      else
        if l:sub(1, 1) ~= " " then s.staged = s.staged + 1 end
        if l:sub(2, 2) ~= " " then s.modified = s.modified + 1 end
      end
    end
  end
  return s
end

local function build_lines()
  local s = state.summary
  if not s then return nil end
  local head = ICON.branch .. (s.branch or "?")
  if s.ahead > 0 then head = head .. "  " .. ICON.ahead .. s.ahead end
  if s.behind > 0 then head = head .. " " .. ICON.behind .. s.behind end
  local lines = { head }

  if s.total == 0 then
    lines[#lines + 1] = ICON.clean .. " clean"
  else
    local parts = {}
    if s.staged > 0 then parts[#parts + 1] = ICON.staged .. s.staged .. " staged" end
    if s.modified > 0 then parts[#parts + 1] = ICON.mod .. s.modified .. " modified" end
    if s.untracked > 0 then parts[#parts + 1] = ICON.untrk .. s.untracked .. " untracked" end
    lines[#lines + 1] = s.total .. " uncommitted"
    if #parts > 0 then lines[#lines + 1] = "  " .. table.concat(parts, "  ") end
  end

  local d = state.distance
  if d then
    local seg
    if d.fetching then
      seg = ICON.base .. "fetching origin…"
    else
      seg = ICON.base .. d.def .. ": "
      if d.ahead == 0 and d.behind == 0 then
        seg = seg .. "up to date"
      else
        seg = seg .. ICON.ahead .. d.ahead .. " " .. ICON.behind .. d.behind
      end
      if d.fetch_failed then seg = seg .. " (stale: fetch failed)" end
    end
    lines[#lines + 1] = seg
  end
  if state.subject and state.subject ~= "" then lines[#lines + 1] = "» " .. state.subject end

  -- footer highlights collected here: { {line0, hl}, ... }
  state._hls = {}
  -- terminal state: show only when a live shared terminal exists for this folder
  local ok, term = pcall(require, "config.shared_term")
  if ok and state.dir and term.has(state.dir) then
    lines[#lines + 1] = ICON.term .. "terminal open"
    state._hls[#state._hls + 1] = { #lines - 1, "DiagnosticOk" }
  end
  -- local base branch freshness (gf fast-forwards it in place unless you're on it)
  local db = state.distance
  if db and not db.fetching and db.base_fresh then
    if db.base_fresh == "diverged" then
      lines[#lines + 1] = ICON.base .. base_branch() .. " diverged — ff failed"
      state._hls[#state._hls + 1] = { #lines - 1, "WarningMsg" }
    else
      lines[#lines + 1] = ICON.base .. base_branch()
        .. (db.base_fresh == "updated" and " freshened" or " fresh")
      state._hls[#state._hls + 1] = { #lines - 1, "Comment" }
    end
  end
  -- actionable line: current branch behind its own upstream → pull / rebase
  local du = state.distance
  if du and not du.fetching and du.up_behind and du.up_behind > 0 then
    if du.up_ahead == 0 then
      lines[#lines + 1] = ICON.behind .. du.up_behind .. " behind upstream — gp to pull"
    else
      lines[#lines + 1] = ICON.behind .. du.up_behind .. " " .. ICON.ahead .. du.up_ahead
        .. " diverged — gb to rebase"
    end
    state._hls[#state._hls + 1] = { #lines - 1, "WarningMsg" }
  end
  -- hotkey hints (dimmed)
  lines[#lines + 1] = HINTS
  state._hls[#state._hls + 1] = { #lines - 1, "Comment" }
  return lines
end

local function render()
  local lines = build_lines()
  if lines then show(lines) end
end

-- Gather the cheap status + last commit for `dir`, then render.
local function update(dir)
  local mine = seq
  vim.system({ "git", "-C", dir, "status", "--porcelain=v1", "--branch", "--", "." },
    { text = true }, function(st)
      if st.code ~= 0 or not st.stdout then
        vim.schedule(function() if seq == mine then M.close() end end)
        return
      end
      local summary = parse(st.stdout)
      vim.system({ "git", "-C", dir, "log", "-1", "--format=%s  (%cr)" },
        { text = true }, function(lg)
          vim.schedule(function()
            if seq ~= mine then return end   -- cursor moved on; drop stale result
            state.dir = dir
            state.summary = summary
            state.subject = (lg.code == 0 and lg.stdout or ""):gsub("%s+$", "")
            state.distance = nil
            render()
          end)
        end)
    end)
end

-- Fast-forward the local base branch (develop) in place, unless HEAD is sitting on
-- it. Purely local ref advance via `fetch <remote> <base>:<base>` (ff-only, so a
-- diverged base is rejected, never forced). Calls cb with a short status string:
-- "fresh" | "updated" | "diverged" | nil (on base / not applicable).
local function freshen_base_quiet(dir, cb)
  local remote, base = remote_name(), base_branch()
  vim.system({ "git", "-C", dir, "symbolic-ref", "--quiet", "--short", "HEAD" },
    { text = true }, function(rc)
      local cur = (rc.code == 0 and rc.stdout or ""):gsub("%s+$", "")
      if cur == base then cb(nil); return end -- on base → gp/normal fetch handles it
      vim.system({ "git", "-C", dir, "fetch", remote, base .. ":" .. base },
        { text = true }, function(rb)
          local out = (rb.stderr or "") .. (rb.stdout or "")
          local status
          if rb.code == 0 then
            status = out:match("%->") and "updated" or "fresh"
          elseif out:match("non%-fast%-forward") or out:match("%[rejected%]") then
            status = "diverged"
          end
          cb(status)
        end)
    end)
end

-- Public: fetch origin, then add "distance from origin's default branch" to the
-- popup for the folder under the cursor. Bound to a key because it touches the
-- network and is the extra git work.
function M.show_distance()
  local ok, api = pcall(require, "nvim-tree.api")
  if not ok then return end
  local node = api.tree.get_node_under_cursor()
  if not (node and node.type == "directory" and node.absolute_path) then return end
  local dir = node.absolute_path
  local mine = seq

  -- Compute distance from origin's default branch (after a fetch attempt).
  local function compute(fetch_failed, base_fresh)
    vim.system({ "git", "-C", dir, "rev-parse", "--abbrev-ref", "origin/HEAD" },
      { text = true }, function(r)
        local def = (r.code == 0 and r.stdout or ""):gsub("%s+$", "")
        if def == "" then def = "origin/main" end
        vim.system({ "git", "-C", dir, "rev-list", "--left-right", "--count", def .. "...HEAD" },
          { text = true }, function(r2)
            -- Also measure the current branch against its OWN upstream, so we can
            -- tell whether a plain `git pull --ff-only` would help (gp hint below).
            vim.system({ "git", "-C", dir, "rev-list", "--left-right", "--count", "@{u}...HEAD" },
              { text = true }, function(r3)
                vim.schedule(function()
                  if seq ~= mine or state.dir ~= dir then return end
                  if r2.code ~= 0 or not r2.stdout then
                    vim.notify("[tree-git] no upstream default branch found", vim.log.levels.WARN)
                    state.distance = nil
                    render()
                    return
                  end
                  local behind, ahead = r2.stdout:match("(%d+)%s+(%d+)")
                  local ub, ua = "0", "0"
                  if r3.code == 0 and r3.stdout then ub, ua = r3.stdout:match("(%d+)%s+(%d+)") end
                  state.distance = {
                    def = def, ahead = tonumber(ahead) or 0, behind = tonumber(behind) or 0,
                    up_behind = tonumber(ub) or 0, up_ahead = tonumber(ua) or 0,
                    fetch_failed = fetch_failed, base_fresh = base_fresh,
                  }
                  render()
                end)
              end)
          end)
      end)
  end

  -- Show a transient "fetching…" line, then fetch origin and compute.
  if state.dir == dir then
    state.distance = { fetching = true }
    render()
  end
  vim.system({ "git", "-C", dir, "fetch", "origin", "--quiet" }, { text = true }, function(rf)
    -- After remote-tracking refs are updated, also fast-forward the local base
    -- branch in place, so a single gf both reports distance and keeps develop fresh.
    freshen_base_quiet(dir, function(base_fresh)
      vim.schedule(function()
        if seq ~= mine or state.dir ~= dir then return end
        compute(rf.code ~= 0, base_fresh)
      end)
    end)
  end)
end

-- Public: fast-forward pull the current branch of the repo under the cursor from
-- its upstream. Refuses to merge/rebase (--ff-only), so it's safe: it either
-- advances the branch or does nothing. On a diverged branch it fails cleanly and
-- points at gb (rebase). Refreshes the popup afterwards.
function M.pull_ff()
  local ok, api = pcall(require, "nvim-tree.api")
  if not ok then return end
  local node = api.tree.get_node_under_cursor()
  if not (node and node.type == "directory" and node.absolute_path) then return end
  local dir = node.absolute_path
  vim.notify("[tree-git] pulling (fast-forward)…", vim.log.levels.INFO)
  vim.system({ "git", "-C", dir, "pull", "--ff-only", "--quiet" }, { text = true }, function(rp)
    vim.schedule(function()
      if rp.code == 0 then
        vim.notify("[tree-git] pulled (fast-forward)", vim.log.levels.INFO)
      else
        local err = ((rp.stderr or "") .. (rp.stdout or "")):gsub("%s+$", "")
        vim.notify("[tree-git] pull failed: " .. err .. "\n(diverged? use gb to rebase)",
          vim.log.levels.WARN)
      end
      -- refresh distance/status in the popup for the same folder
      if state.dir == dir then M.show_distance() end
    end)
  end)
end

-- CursorMoved in the tree buffer: show/refresh/close as the cursor moves.
local function on_move()
  local ok, api = pcall(require, "nvim-tree.api")
  if not ok then return end
  local node = api.tree.get_node_under_cursor()
  seq = seq + 1
  if not (node and node.type == "directory" and node.absolute_path) then
    M.close()
    return
  end
  local dir = node.absolute_path
  if dir == state.dir then return end   -- already showing this folder
  state.treewin = vim.api.nvim_get_current_win()
  timer:stop()
  timer:start(120, 0, vim.schedule_wrap(function() update(dir) end))
end

-- Attach to a tree buffer (call from nvim-tree on_attach).
function M.attach(bufnr)
  local grp = vim.api.nvim_create_augroup("TreeGitPopup_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = grp, buffer = bufnr, callback = on_move,
  })
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave", "BufWinLeave" }, {
    group = grp, buffer = bufnr,
    callback = function() seq = seq + 1; M.close() end,
  })
end

return M
