-- review_view: a small standalone red/green patch-review screen (gR).
--
-- Two panes in their own tabpage:
--   left  = grouped/indented list of files changed in <base>...HEAD (feature vs default)
--   right = a SINGLE unified red(-)/green(+) diff buffer for the selected file
--
-- Pressing `r` on a file runs the `claude` agent review on that one file. Findings
-- (LOC: <file>:<line> <msg>) are mapped from new-file line numbers onto rows of the
-- unified diff buffer, then published as quickfix entries that reference the diff
-- buffer itself — so :cnext/:cprev (and ]q/[q) navigate WITHIN the red/green screen
-- instead of jumping to the plain source file. Findings also show as inline
-- diagnostics + signs on the flagged rows.
--
-- Reuses: config.review_context (diff / commit subjects), config.agent_runner
-- (claude streaming), and settings_local.diff_review (claude_command/model/env).

local M = {}

local MAX_DIFF_CHARS = 7000
local NS = vim.api.nvim_create_namespace("review_view")          -- diagnostics
local HL_NS = vim.api.nvim_create_namespace("review_view_hl")    -- +/- line backgrounds
local SIDE_NS = vim.api.nvim_create_namespace("review_view_side") -- sidebar headers/counts
local SIDEBAR_WIDTH = 42

-- Subtle full-line backgrounds for added/removed lines, layered over filetype=diff
-- foreground coloring. Re-applied on ColorScheme so it survives theme changes.
local function ensure_hl()
  local dark = vim.o.background == "dark"
  vim.api.nvim_set_hl(0, "ReviewViewAddLine", { bg = dark and "#16291d" or "#e6ffec" })
  vim.api.nvim_set_hl(0, "ReviewViewDelLine", { bg = dark and "#33181b" or "#ffebe9" })
  vim.api.nvim_set_hl(0, "ReviewViewChangeLine", { bg = dark and "#33301a" or "#fff5b1" })
  vim.api.nvim_set_hl(0, "ReviewViewDir", { link = "Directory" })
  vim.api.nvim_set_hl(0, "ReviewViewAdd", { link = "diffAdded" })
  vim.api.nvim_set_hl(0, "ReviewViewDel", { link = "diffRemoved" })
  vim.api.nvim_set_hl(0, "ReviewViewDirty", { link = "DiagnosticWarn" })
end
ensure_hl()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("ReviewViewHL", { clear = true }),
  callback = ensure_hl,
})

local REVIEW_PROMPT = [[Review this diff for bugs, type errors, logic errors, security issues.
Also check comments: flag any that are inaccurate or misleading about what the code actually does,
contain outdated history or change-log notes that belong in git commit messages instead,
or describe unrelated concerns irrelevant to the surrounding block.
Each added/context line in the diff is prefixed with its line number and a TAB
(e.g. "188\t+ ..."). Use that exact prefixed number as <line_number> — do not
count lines yourself. Only report on lines that have a number.
For each issue output exactly ONE line:
LOC: <file_path>:<line_number> <brief description>
After all issues: one-sentence summary. No other text.]]

-- Single active view state.
local S = nil

local function git(root, args)
  local cmd = { "git", "-C", root }
  vim.list_extend(cmd, args)
  local out = vim.fn.systemlist(cmd)
  return vim.v.shell_error == 0, out
end

-- Mirror of tree.lua resolve_base: try git_base, then main/master/develop and
-- their origin/ variants, finally origin/HEAD.
local function resolve_base(root)
  local ok, settings_local = pcall(require, "config.settings_local")
  local git_base = (ok and type(settings_local) == "table" and settings_local.git_base_branch) or "main"
  local function verify(ref)
    vim.fn.systemlist({ "git", "-C", root, "rev-parse", "--verify", "--quiet", ref })
    return vim.v.shell_error == 0
  end
  local candidates = { git_base, "origin/" .. git_base }
  for _, b in ipairs({ "main", "master", "develop" }) do
    if b ~= git_base then
      table.insert(candidates, b)
      table.insert(candidates, "origin/" .. b)
    end
  end
  for _, c in ipairs(candidates) do
    if verify(c) then return c, git_base end
  end
  local okh, out = git(root, { "symbolic-ref", "--short", "refs/remotes/origin/HEAD" })
  if okh and out[1] and out[1] ~= "" then return out[1], git_base end
  return nil, git_base
end

-- A set of path names from a `git` name-only command.
local function name_set(root, args)
  local ok, out = git(root, args)
  local s = {}
  if ok then for _, l in ipairs(out) do if l ~= "" then s[l] = true end end end
  return s
end

-- Build the changed-file list over <merge_base>..WORKING-TREE — i.e. committed
-- feature changes AND uncommitted edits — plus untracked files. Each entry is
-- tagged committed / dirty / untracked so the sidebar can differentiate.
local function collect_files(root, base, merge_base, head)
  -- which files have committed changes (base...HEAD) vs uncommitted (vs HEAD)
  local committed = name_set(root, { "diff", "--name-only", base .. "..." .. head })
  local dirty     = name_set(root, { "diff", "--name-only", "HEAD" })

  local files, seen = {}, {}
  -- numstat of merge_base..working-tree: tracked changes, committed + uncommitted
  local ok, out = git(root, { "diff", "--numstat", merge_base })
  if ok then
    for _, line in ipairs(out) do
      local adds, dels, path = line:match("^(%S+)\t(%S+)\t(.+)$")
      if path then
        local binary = (adds == "-" or dels == "-")
        files[#files + 1] = {
          path = path,
          adds = binary and 0 or tonumber(adds) or 0,
          dels = binary and 0 or tonumber(dels) or 0,
          binary = binary,
          committed = committed[path] or false,
          dirty = dirty[path] or false,
        }
        seen[path] = true
      end
    end
  end
  -- untracked files (new, not yet added) — all-added when shown
  local uok, uout = git(root, { "ls-files", "--others", "--exclude-standard" })
  if uok then
    for _, path in ipairs(uout) do
      if path ~= "" and not seen[path] then
        files[#files + 1] = { path = path, adds = 0, dels = 0, untracked = true, dirty = true }
        seen[path] = true
      end
    end
  end
  table.sort(files, function(a, b) return a.path < b.path end)
  return files
end

-- Render the grouped/indented sidebar. Returns line_index: buffer row -> file entry.
-- Fit `s` to exactly `w` display columns: truncate with … if too long, pad if short.
local function fit(s, w)
  local dw = vim.fn.strdisplaywidth(s)
  if dw > w then
    s = vim.fn.strcharpart(s, 0, w - 1) .. "…"
    dw = vim.fn.strdisplaywidth(s)
  end
  if dw < w then s = s .. string.rep(" ", w - dw) end
  return s
end

local function render_sidebar(buf, st)
  local width = (st.sidebar_win and vim.api.nvim_win_is_valid(st.sidebar_win))
    and vim.api.nvim_win_get_width(st.sidebar_win) or SIDEBAR_WIDTH
  local indent, gap, countw = 4, 1, 9
  local namew = math.max(8, width - indent - gap - countw)

  local lines = {}
  local line_index = {}   -- row -> file entry
  local dir_index = {}    -- row -> dir name (header rows)
  local hi = {}           -- { row, kind, [col_a, col_b] } highlight ops

  table.insert(lines, ("%s → working tree  (%d files)"):format(st.base, #st.files))
  table.insert(lines, "● uncommitted   + new   (blank = committed)")
  table.insert(lines, "? help   q quit   R reload   C chat")
  table.insert(lines, "")

  -- group by directory
  local groups, order = {}, {}
  for _, f in ipairs(st.files) do
    local dir = vim.fn.fnamemodify(f.path, ":h")
    if dir == "" then dir = "." end
    if not groups[dir] then groups[dir] = {}; table.insert(order, dir) end
    table.insert(groups[dir], f)
  end
  table.sort(order)

  for _, dir in ipairs(order) do
    local collapsed = st.collapsed[dir]
    local arrow = collapsed and "▸" or "▾"
    table.insert(lines, ("%s %s/  (%d)"):format(arrow, dir, #groups[dir]))
    dir_index[#lines] = dir
    table.insert(hi, { row = #lines - 1, kind = "dir" })
    if not collapsed then
      for _, f in ipairs(groups[dir]) do
        local name = vim.fn.fnamemodify(f.path, ":t")
        local counts = f.binary and "bin" or ("+%d -%d"):format(f.adds, f.dels)
        -- status marker: + new (untracked), ● uncommitted (dirty), blank = committed
        local mk, mk_hl = " ", nil
        if f.untracked then mk, mk_hl = "+", "ReviewViewAdd"
        elseif f.dirty then mk, mk_hl = "●", "ReviewViewDirty" end
        local prefix = "  " .. mk .. " "   -- 2 spaces + marker + space = same width as indent(4)
        local row_text = prefix .. fit(name, namew) .. " "
          .. string.rep(" ", math.max(0, countw - #counts)) .. counts
        table.insert(lines, row_text)
        line_index[#lines] = f
        if mk_hl then
          table.insert(hi, { row = #lines - 1, kind = "mark", a = 2, b = 2 + #mk, hl = mk_hl })
        end
        -- color the counts (split into +adds / -dels for green/red)
        local cstart = #row_text - #counts
        local plus = counts:match("^(%+%d+)")
        if plus then table.insert(hi, { row = #lines - 1, kind = "add", a = cstart, b = cstart + #plus }) end
        local minus_at = counts:find(" %-%d+")
        if minus_at then
          table.insert(hi, { row = #lines - 1, kind = "del", a = cstart + minus_at, b = #row_text })
        end
      end
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, SIDE_NS, 0, -1)
  for _, h in ipairs(hi) do
    if h.kind == "dir" then
      vim.api.nvim_buf_set_extmark(buf, SIDE_NS, h.row, 0, { end_row = h.row + 1, hl_group = "ReviewViewDir" })
    elseif h.kind == "add" then
      vim.api.nvim_buf_set_extmark(buf, SIDE_NS, h.row, h.a, { end_col = h.b, hl_group = "ReviewViewAdd" })
    elseif h.kind == "del" then
      vim.api.nvim_buf_set_extmark(buf, SIDE_NS, h.row, h.a, { end_col = h.b, hl_group = "ReviewViewDel" })
    elseif h.kind == "mark" then
      vim.api.nvim_buf_set_extmark(buf, SIDE_NS, h.row, h.a, { end_col = h.b, hl_group = h.hl })
    end
  end

  st.line_index = line_index
  st.dir_index = dir_index
end

local function new_scratch(ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  if ft then vim.bo[buf].filetype = ft end
  return buf
end

-- Quickfix-navigation keymaps for the diff / placeholder buffers.
local function setup_diff_keymaps(buf)
  local o = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "]q", function() M.qf_next() end, o)
  vim.keymap.set("n", "[q", function() M.qf_prev() end, o)
  vim.keymap.set("n", "R", function() M.refresh() end, o)
  vim.keymap.set("n", "C", function() M.codecompanion() end, o)
  vim.keymap.set("x", "C", function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    M.codecompanion({ visual = true })
  end, o)
  vim.keymap.set("n", "e", function() M.edit_under_cursor() end, o)
  vim.keymap.set("n", "X", function() M.revert_under_cursor() end, o)
  vim.keymap.set("n", "?", function() M.show_help() end, o)
  vim.keymap.set("n", "q", function() M.close() end, o)
end

-- Re-display the help/cheatsheet (the placeholder buffer) in the diff pane.
function M.show_help()
  if S and vim.api.nvim_win_is_valid(S.diff_win) and S.placeholder_buf then
    vim.api.nvim_win_set_buf(S.diff_win, S.placeholder_buf)
  end
end

-- Inverse of map_line: a diff-buffer row -> its source line (exact, else the
-- nearest mapped row above it, else 1). For untracked full-content buffers the
-- linemap is identity, so this returns the row unchanged.
local function src_for_row(linemap, row)
  if not linemap then return row end
  local best_src, best_row
  for src, r in pairs(linemap) do
    if r == row then return src end
    if r <= row and (not best_row or r > best_row) then best_row, best_src = r, src end
  end
  return best_src or 1
end

-- Map a reported new-file line to a diff-buffer row (exact, else nearest <=, else 1).
local function map_line(linemap, lnum)
  if linemap[lnum] then return linemap[lnum] end
  local best, best_row
  for nl, row in pairs(linemap) do
    if nl <= lnum and (not best or nl > best) then best, best_row = nl, row end
  end
  return best_row or 1
end

-- Annotate a unified diff with new-file line numbers (added/context lines get an
-- "N<TAB>" prefix) so an LLM checker copies the number instead of counting lines.
local function numbered_diff(diff)
  local out, newln = {}, nil
  for _, line in ipairs(vim.split(diff, "\n", { plain = true })) do
    local h = line:match("^@@ %-%d+,?%d* %+(%d+)")
    if h then
      newln = tonumber(h); out[#out + 1] = line
    elseif newln and not line:match("^%+%+%+") and not line:match("^%-%-%-")
        and (line:sub(1, 1) == "+" or line:sub(1, 1) == " ") then
      out[#out + 1] = ("%d\t%s"):format(newln, line); newln = newln + 1
    else
      out[#out + 1] = line
    end
  end
  return table.concat(out, "\n")
end

-- Classify per-line diff status of the working-tree version of `path` (via -U0):
--   added[n]=true (green), changed[n]=true (yellow)  — n is a new-file line,
--   dels = { { line=n, above=bool, lines={removed text} } }  (red, shown as virt lines)
local function diff_status(root, merge_base, path)
  local added, changed, dels = {}, {}, {}
  local dl = vim.fn.systemlist({ "git", "-C", root, "diff", "-U0", merge_base, "--", path })
  local i = 1
  while i <= #dl do
    local nl, nc = dl[i]:match("^@@ %-%d+,?%d* %+(%d+),?(%d*) @@")
    if nl then
      nl, nc = tonumber(nl), (nc == "" and 1 or tonumber(nc))
      local removed, j, adds = {}, i + 1, 0
      while j <= #dl and not dl[j]:match("^@@") do
        local c = dl[j]:sub(1, 1)
        if c == "-" then removed[#removed + 1] = dl[j]:sub(2)
        elseif c == "+" then adds = adds + 1 end
        j = j + 1
      end
      if #removed == 0 then
        for k = 0, nc - 1 do added[nl + k] = true end
      elseif nc == 0 then
        dels[#dels + 1] = { line = nl, above = false, lines = removed }   -- pure deletion
      else
        for k = 0, nc - 1 do changed[nl + k] = true end
        dels[#dels + 1] = { line = nl, above = true, lines = removed }    -- replacement
      end
      i = j
    else
      i = i + 1
    end
  end
  return added, changed, dels
end

-- Parse the merge-base→working-tree diff for `path` into hunks, keeping each
-- hunk's new-file range (nl .. nl+nc-1) and its removed (base/develop) lines, so
-- a single change can be reverted to its base state.
local function parse_hunks(root, merge_base, path)
  local dl = vim.fn.systemlist({ "git", "-C", root, "diff", "-U0", merge_base, "--", path })
  local hunks, i = {}, 1
  while i <= #dl do
    local nl, nc = dl[i]:match("^@@ %-%d+,?%d* %+(%d+),?(%d*) @@")
    if nl then
      nl, nc = tonumber(nl), (nc == "" and 1 or tonumber(nc))
      local removed, j = {}, i + 1
      while j <= #dl and not dl[j]:match("^@@") do
        if dl[j]:sub(1, 1) == "-" then removed[#removed + 1] = dl[j]:sub(2) end
        j = j + 1
      end
      hunks[#hunks + 1] = { nl = nl, nc = nc, removed = removed }
      i = j
    else
      i = i + 1
    end
  end
  return hunks
end

-- Build (and cache) the review buffer for one file. Default: the WHOLE file with
-- the diff painted over it (green added, yellow changed, red deleted as virtual
-- lines) and real syntax highlighting; buffer row == source line. Deleted/binary
-- files fall back to a unified-diff buffer. Returns bufnr, diff_text, linemap.
local function ensure_file_buf(st, entry)
  local path = entry.path
  local cached = st.file_bufs[path]
  if cached and vim.api.nvim_buf_is_valid(cached) then
    return cached, st.diffs[path], st.linemaps[path]
  end

  local rc = require("config.review_context")
  local abspath = st.root .. "/" .. path

  -- the real unified diff is kept for the checker prompt regardless of how we render
  local diff
  if entry.untracked then
    diff = table.concat(vim.fn.systemlist({
      "git", "-C", st.root, "diff", "--no-index", "--", "/dev/null", path,
    }), "\n")
  else
    diff = rc.diff(st.root, st.merge_base, nil, path, { right_is_local = true }) or ""
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"

  local linemap = {}
  local readable = vim.fn.filereadable(abspath) == 1 and not entry.binary

  if readable then
    -- FULL FILE + diff overlay
    local content = vim.fn.readfile(abspath)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
    local ft = vim.filetype.match({ filename = abspath, buf = buf }) or ""
    if ft ~= "" then vim.bo[buf].filetype = ft end
    vim.bo[buf].modifiable = false

    for n = 1, #content do linemap[n] = n end   -- identity: row == source line

    local added, changed, dels
    if entry.untracked then
      added, changed, dels = {}, {}, {}
      for n = 1, #content do added[n] = true end
    else
      added, changed, dels = diff_status(st.root, st.merge_base, path)
    end
    for n in pairs(added) do
      if n >= 1 and n <= #content then
        vim.api.nvim_buf_set_extmark(buf, HL_NS, n - 1, 0, { line_hl_group = "ReviewViewAddLine" })
      end
    end
    for n in pairs(changed) do
      if n >= 1 and n <= #content then
        vim.api.nvim_buf_set_extmark(buf, HL_NS, n - 1, 0, { line_hl_group = "ReviewViewChangeLine" })
      end
    end
    for _, d in ipairs(dels) do
      local virt = {}
      for _, rl in ipairs(d.lines) do virt[#virt + 1] = { { "- " .. rl, "ReviewViewDelLine" } } end
      local above = d.above or d.line == 0
      local row = math.max(0, (d.line == 0 and 1 or d.line) - 1)
      vim.api.nvim_buf_set_extmark(buf, HL_NS, row, 0, { virt_lines = virt, virt_lines_above = above })
    end
  else
    -- FALLBACK: deleted/binary/unreadable → unified-diff buffer (hunk view)
    local dtext = (vim.trim(diff) ~= "" and diff) or ("(no preview for " .. path .. ")")
    local dlines = vim.split(dtext, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, dlines)
    vim.bo[buf].filetype = "diff"
    vim.bo[buf].modifiable = false
    local newln
    for i, line in ipairs(dlines) do
      local hh = line:match("^@@ %-%d+,?%d* %+(%d+)")
      if hh then newln = tonumber(hh)
      elseif newln then
        local c = line:sub(1, 1)
        if line:match("^%+%+%+") or line:match("^%-%-%-") then
        elseif c == "+" or c == " " then linemap[newln] = i; newln = newln + 1 end
      end
    end
    for i, line in ipairs(dlines) do
      local c = line:sub(1, 1)
      if line:match("^%+%+%+") or line:match("^%-%-%-") then
      elseif c == "+" then vim.api.nvim_buf_set_extmark(buf, HL_NS, i - 1, 0, { line_hl_group = "ReviewViewAddLine" })
      elseif c == "-" then vim.api.nvim_buf_set_extmark(buf, HL_NS, i - 1, 0, { line_hl_group = "ReviewViewDelLine" })
      end
    end
  end

  setup_diff_keymaps(buf)
  st.file_bufs[path] = buf
  st.diffs[path] = diff
  st.linemaps[path] = linemap
  return buf, diff, linemap
end

-- Display a file's diff in the right pane (no checker run).
local function show_file(st, entry)
  if not entry then return end
  local buf = ensure_file_buf(st, entry)
  st.current_file = entry
  if vim.api.nvim_win_is_valid(st.diff_win) then
    vim.api.nvim_win_set_buf(st.diff_win, buf)
    pcall(vim.api.nvim_win_set_cursor, st.diff_win, { 1, 0 })
  end
end

-- Resolve the configured checker list. Falls back to a single AI checker built
-- from the existing settings_local.diff_review config.
local function get_checkers()
  local ok, sl = pcall(require, "config.settings_local")
  local rv = ok and type(sl) == "table" and sl.review_view
  if rv and type(rv.checkers) == "table" and #rv.checkers > 0 then
    return rv.checkers
  end
  local dr = (ok and type(sl) == "table" and sl.diff_review) or {}
  local claude = dr.claude_command or vim.fn.exepath("claude")
  local cmd = { claude, "-p", "--no-session-persistence" }
  if dr.model then vim.list_extend(cmd, { "--model", dr.model }) end
  return { {
    name = "ai",
    cmd = cmd,
    input = "prompt",
    env = vim.tbl_extend("force", { CLAUDECODE = "" }, dr.env or {}),
  } }
end

-- Rebuild quickfix + per-buffer diagnostics from the accumulated item list.
local function publish(st)
  if st ~= S then return end   -- view was closed / replaced: ignore late callbacks
  -- drop items whose buffer was wiped (e.g. closed mid-check) to avoid E92
  local items = {}
  for _, it in ipairs(st.items) do
    if it.bufnr and vim.api.nvim_buf_is_valid(it.bufnr) then items[#items + 1] = it end
  end
  st.items = items
  vim.fn.setqflist({}, "r", { title = "Review checkers", items = items })
  local by_buf = {}
  for _, it in ipairs(items) do
    by_buf[it.bufnr] = by_buf[it.bufnr] or {}
    table.insert(by_buf[it.bufnr], {
      lnum = it.lnum - 1, col = 0, message = it.text,
      severity = vim.diagnostic.severity.WARN, source = "ReviewView",
    })
  end
  -- clear all our diagnostics, then re-set per buffer that still has items
  vim.diagnostic.reset(NS)
  for buf, diags in pairs(by_buf) do
    if vim.api.nvim_buf_is_valid(buf) then vim.diagnostic.set(NS, buf, diags) end
  end
end

-- Quickfix navigation that stays INSIDE the review diff window (never splits).
local function qf_show(idx)
  local all = vim.fn.getqflist()
  if #all == 0 then return end
  idx = math.max(1, math.min(idx, #all))
  vim.fn.setqflist({}, "r", { idx = idx })   -- move the current marker, keep items
  local it = all[idx]
  if not (it and it.bufnr and it.bufnr > 0) then return end
  if not (S and vim.api.nvim_win_is_valid(S.diff_win)) then return end
  vim.api.nvim_win_set_buf(S.diff_win, it.bufnr)
  vim.api.nvim_set_current_win(S.diff_win)
  pcall(vim.api.nvim_win_set_cursor, S.diff_win, { it.lnum > 0 and it.lnum or 1, 0 })
end

function M.qf_jump() qf_show(vim.fn.line(".")) end                              -- from qf win: line == index
function M.qf_next() qf_show((vim.fn.getqflist({ idx = 0 }).idx or 0) + 1) end
function M.qf_prev() qf_show((vim.fn.getqflist({ idx = 0 }).idx or 0) - 1) end

-- Open the quickfix window at the bottom without stealing focus, and route <CR>
-- in it to the review diff window (so selecting a finding never opens a split).
local function ensure_qf_open()
  local qf_win
  for _, w in ipairs(vim.fn.getwininfo()) do
    if w.quickfix == 1 and w.loclist == 0 then qf_win = w.winid end
  end
  if not qf_win then
    local cur = vim.api.nvim_get_current_win()
    vim.cmd("botright copen")
    qf_win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_is_valid(cur) then pcall(vim.api.nvim_set_current_win, cur) end
  end
  local qbuf = vim.api.nvim_win_get_buf(qf_win)
  vim.keymap.set("n", "<CR>", function() M.qf_jump() end, { buffer = qbuf, nowait = true, silent = true })
end

-- Substitute ${file} / ${path} placeholders in a checker's argv.
local function expand_cmd(cmd, abspath, relpath)
  local out = {}
  for _, a in ipairs(cmd) do
    a = a:gsub("${file}", abspath):gsub("${path}", relpath)
    table.insert(out, a)
  end
  return out
end

-- Run every configured checker on one file, asynchronously, merging LOC output
-- into the shared quickfix list + the file's diff buffer.
local function run_checkers(st, entry, opts)
  if not entry then return end
  opts = opts or {}
  local path = entry.path

  -- Always switch the diff pane to the selected file.
  local buf, diff, linemap = ensure_file_buf(st, entry)
  show_file(st, entry)

  -- Only the checker run is guarded: skip if already running or already done
  -- (unless forced via `r`). The view still switched above.
  if st.inflight[path] then return end
  if st.done[path] and not opts.force then return end

  -- drop any previous items for this file (re-run / refresh)
  st.items = vim.tbl_filter(function(it) return it._file ~= path end, st.items)
  st.done[path] = nil

  local checkers = get_checkers()
  local scope = vim.fn.fnamemodify(path, ":t")

  -- prompt body (for input="prompt" checkers)
  local rc = require("config.review_context")
  local pdiff = diff
  if #pdiff > MAX_DIFF_CHARS then pdiff = pdiff:sub(1, MAX_DIFF_CHARS) .. "\n[...truncated]" end
  local subjects = rc.format_subjects(rc.commit_subjects(st.root, st.merge_base, "HEAD", 10))
  local pparts = { REVIEW_PROMPT, "" }
  if subjects then table.insert(pparts, "Commits:"); table.insert(pparts, subjects); table.insert(pparts, "") end
  table.insert(pparts, "File: " .. path); table.insert(pparts, "")
  table.insert(pparts, "Diff (added/context lines prefixed with `<line-number><TAB>`):")
  table.insert(pparts, "```"); table.insert(pparts, numbered_diff(pdiff)); table.insert(pparts, "```")
  local prompt = table.concat(pparts, "\n")

  local abspath = st.root .. "/" .. path
  local runner = require("config.agent_runner")
  local pending = 0
  st.inflight[path] = 0

  vim.notify(("review_view: %s — running %d checker(s)..."):format(scope, #checkers), vim.log.levels.INFO)

  for _, chk in ipairs(checkers) do
    local cmd = chk.cmd
    if type(cmd) == "string" then cmd = { cmd } end
    if type(cmd) == "table" and cmd[1] then
      cmd = expand_cmd(cmd, abspath, path)
      local input = chk.input or "prompt"
      local stdin = (input == "prompt" and prompt) or (input == "diff" and diff) or nil
      local name = chk.name or cmd[1]:match("[^/]+$") or "checker"

      pending = pending + 1
      st.inflight[path] = pending

      runner.run_cmd(cmd, {
        label = scope .. ":" .. name,
        env = chk.env,
        stdin = stdin,
        on_line = function(line)
          if st ~= S then return end   -- view closed/replaced
          local _, lnum, msg = line:match("^LOC:%s*([^:]+):(%d+)%s+(.+)")
          if not (lnum and msg) then return end
          if not vim.api.nvim_buf_is_valid(buf) then return end
          local row = map_line(linemap, tonumber(lnum))
          table.insert(st.items, {
            bufnr = buf, lnum = row, col = 1,
            text = "[" .. name .. "] " .. msg, type = "W",
            _file = path, _checker = name,
          })
          vim.schedule(function() publish(st) end)
        end,
        on_exit = function(code, stderr)
          vim.schedule(function()
            if st ~= S then return end   -- view closed/replaced: drop late results
            pending = pending - 1
            st.inflight[path] = pending
            if code ~= 0 and stderr ~= "" then
              vim.notify(("review_view: %s:%s exited %d\n%s"):format(scope, name, code, stderr),
                vim.log.levels.WARN)
            end
            publish(st)
            if pending <= 0 then
              st.inflight[path] = nil
              st.done[path] = true
              local n = 0
              for _, it in ipairs(st.items) do if it._file == path then n = n + 1 end end
              if n > 0 then
                -- show results at the bottom without yanking focus from wherever you are
                ensure_qf_open()
                vim.notify(("review_view: %s — %d issue(s)"):format(scope, n), vim.log.levels.WARN)
              else
                vim.notify("review_view: " .. scope .. " — no issues", vim.log.levels.INFO)
              end
            end
          end)
        end,
      })
    end
  end

  if pending == 0 then
    st.inflight[path] = nil
    vim.notify("review_view: no valid checkers configured", vim.log.levels.WARN)
  end
end

-- Returns true if a review view was open and got closed, false otherwise.
function M.close()
  if not S then return false end
  vim.diagnostic.reset(NS)
  if S.tabpage and vim.api.nvim_tabpage_is_valid(S.tabpage) and #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, "tabclose")
  end
  -- wipe the per-file scratch buffers + placeholder
  local bufs = vim.tbl_values(S.file_bufs or {})
  if S.placeholder_buf then table.insert(bufs, S.placeholder_buf) end
  for _, b in ipairs(bufs) do
    if b and vim.api.nvim_buf_is_valid(b) then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
  end
  S = nil
  return true
end

-- Recompute the file list + diffs against the CURRENT working tree (e.g. after a
-- git checkout / new commit), wiping cached buffers and findings. Keeps the view.
function M.refresh()
  local st = S
  if not st then return end
  -- remember what's open so we can restore it after the rebuild. Prefer the file
  -- actually shown in the diff pane (in case current_file drifted, e.g. after a
  -- ]q/[q jump), falling back to current_file.
  local diff_buf = vim.api.nvim_win_is_valid(st.diff_win) and vim.api.nvim_win_get_buf(st.diff_win) or nil
  local prev_path = (diff_buf and M.file_for(diff_buf)) or (st.current_file and st.current_file.path)
  local prev_view
  if prev_path and diff_buf == st.file_bufs[prev_path] then
    prev_view = vim.api.nvim_win_call(st.diff_win, function() return vim.fn.winsaveview() end)
  end

  -- refresh refs in case HEAD moved
  local okm, mb = git(st.root, { "merge-base", st.base, "HEAD" })
  if okm and mb[1] and mb[1] ~= "" then st.merge_base = mb[1] end
  local okb, br = git(st.root, { "symbolic-ref", "--short", "HEAD" })
  if okb and br[1] and br[1] ~= "" then st.head_ref = br[1] end

  -- detach the diff pane before wiping its buffers
  if vim.api.nvim_win_is_valid(st.diff_win) and st.placeholder_buf then
    vim.api.nvim_win_set_buf(st.diff_win, st.placeholder_buf)
  end
  for _, b in pairs(st.file_bufs) do
    if vim.api.nvim_buf_is_valid(b) then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
  end
  st.file_bufs, st.diffs, st.linemaps = {}, {}, {}
  st.items, st.done, st.inflight = {}, {}, {}
  st.current_file = nil
  vim.diagnostic.reset(NS)
  vim.fn.setqflist({}, "r", { title = "Review checkers", items = {} })

  st.files = collect_files(st.root, st.base, st.merge_base, st.head_ref)
  render_sidebar(st.sidebar_buf, st)

  -- re-open the same file (if it still has changes) and restore the cursor/view
  if prev_path then
    for _, e in ipairs(st.files) do
      if e.path == prev_path then
        show_file(st, e)
        if prev_view and vim.api.nvim_win_is_valid(st.diff_win) then
          local lines = vim.api.nvim_buf_line_count(st.file_bufs[prev_path] or -1)
          prev_view.lnum = math.min(prev_view.lnum, math.max(1, lines))
          vim.api.nvim_win_call(st.diff_win, function() vim.fn.winrestview(prev_view) end)
        end
        break
      end
    end
  end
  vim.notify(("review_view: refreshed (%d files)"):format(#st.files), vim.log.levels.INFO)
end

local function entry_under_cursor()
  if not S then return nil end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  return S.line_index and S.line_index[row]
end

-- Toggle the directory header under the cursor; re-render keeping the cursor on it.
local function toggle_fold(st)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local dir = st.dir_index and st.dir_index[row]
  if not dir then return false end
  st.collapsed[dir] = not st.collapsed[dir] or nil
  render_sidebar(st.sidebar_buf, st)
  pcall(vim.api.nvim_win_set_cursor, st.sidebar_win, { math.min(row, vim.api.nvim_buf_line_count(st.sidebar_buf)), 0 })
  return true
end

local function fold_all(st, collapsed)
  st.collapsed = {}
  if collapsed then
    for _, f in ipairs(st.files) do
      local d = vim.fn.fnamemodify(f.path, ":h")
      st.collapsed[d == "" and "." or d] = true
    end
  end
  render_sidebar(st.sidebar_buf, st)
end

local function build_ui(st)
  vim.cmd("tabnew")
  st.tabpage = vim.api.nvim_get_current_tabpage()

  -- current window becomes the diff (right) pane; start with an empty placeholder
  -- so nothing runs until the user selects a file.
  st.diff_win = vim.api.nvim_get_current_win()
  st.placeholder_buf = new_scratch(nil)
  vim.api.nvim_buf_set_lines(st.placeholder_buf, 0, -1, false, {
    "",
    "  REVIEW — red/green patch view      (press ? to show this help)",
    "",
    "  SIDEBAR (file list)",
    "    ⏎      show diff / fold folder       r        run checkers",
    "    Tab/za  fold folder                  zM/zR    fold / unfold all",
    "    X       revert WHOLE file → base     C        CodeCompanion chat",
    "    R       refresh                      ]q/[q    prev / next finding",
    "    q       close review",
    "",
    "  DIFF PANE",
    "    e       edit file in a tab           C        CodeCompanion (n/v)",
    "    X       revert change under cursor → base (develop)",
    "    ]q/[q   prev / next finding          R        refresh",
    "    q       close review",
    "",
    "  EDIT TAB (after pressing e)",
    "    gR      save & back to review        gt/gT    switch tab",
  })
  vim.bo[st.placeholder_buf].modifiable = false
  vim.api.nvim_win_set_buf(st.diff_win, st.placeholder_buf)
  setup_diff_keymaps(st.placeholder_buf)

  -- left vertical split for the sidebar
  vim.cmd("topleft vsplit")
  st.sidebar_win = vim.api.nvim_get_current_win()
  st.sidebar_buf = new_scratch("ReviewView")
  vim.api.nvim_win_set_buf(st.sidebar_win, st.sidebar_buf)
  vim.api.nvim_win_set_width(st.sidebar_win, SIDEBAR_WIDTH)
  vim.wo[st.sidebar_win].number = false
  vim.wo[st.sidebar_win].relativenumber = false
  vim.wo[st.sidebar_win].wrap = false

  local o = { buffer = st.sidebar_buf, nowait = true, silent = true }
  vim.keymap.set("n", "<CR>", function()
    -- On a folder header: fold/unfold. On a file: just show its diff (no checkers;
    -- press `r` to run the checkers on the current file).
    if toggle_fold(st) then return end
    local e = entry_under_cursor()
    if e then show_file(st, e) end
  end, o)
  vim.keymap.set("n", "r", function()
    local e = entry_under_cursor()
    if e then run_checkers(st, e, { force = true }) end
  end, o)
  vim.keymap.set("n", "<Tab>", function() toggle_fold(st) end, o)
  vim.keymap.set("n", "za", function() toggle_fold(st) end, o)
  vim.keymap.set("n", "zM", function() fold_all(st, true) end, o)
  vim.keymap.set("n", "zR", function() fold_all(st, false) end, o)
  vim.keymap.set("n", "R", function() M.refresh() end, o)
  vim.keymap.set("n", "X", function() M.revert_file_under_cursor() end, o)
  vim.keymap.set("n", "C", function() M.codecompanion({ entry = entry_under_cursor() }) end, o)
  vim.keymap.set("n", "?", function() M.show_help() end, o)
  vim.keymap.set("n", "q", M.close, o)
  vim.keymap.set("n", "]q", function() M.qf_next() end, o)
  vim.keymap.set("n", "[q", function() M.qf_prev() end, o)
end

-- Open the review view for the repo containing `path` (file or directory).
function M.open(path)
  local dir = path and vim.fn.isdirectory(path) == 1 and path
    or (path and vim.fn.fnamemodify(path, ":h"))
    or vim.fn.getcwd()

  local ok, out = git(dir, { "rev-parse", "--show-toplevel" })
  if not ok or not out[1] or out[1] == "" then
    vim.notify("review_view: not a git repo: " .. dir, vim.log.levels.WARN)
    return
  end
  local root = out[1]

  local base = resolve_base(root)
  if not base then
    vim.notify("review_view: no base branch found", vim.log.levels.WARN)
    return
  end

  local okb, branch = git(root, { "symbolic-ref", "--short", "HEAD" })
  local head_ref = (okb and branch[1] and branch[1] ~= "") and branch[1] or "HEAD"

  local okm, mb = git(root, { "merge-base", base, "HEAD" })
  local merge_base = (okm and mb[1] and mb[1] ~= "") and mb[1] or base

  local files = collect_files(root, base, merge_base, head_ref)
  if #files == 0 then
    vim.notify(("review_view: no changes in %s...%s"):format(base, head_ref), vim.log.levels.INFO)
    return
  end

  -- replace any previous view
  if S then M.close() end
  S = {
    root = root, base = base, head_ref = head_ref, merge_base = merge_base,
    files = files, collapsed = {},
    file_bufs = {}, diffs = {}, linemaps = {},  -- per-file caches
    items = {},                                 -- accumulated quickfix items (tagged _file/_checker)
    inflight = {}, done = {},                    -- path -> running count / completed
  }
  -- start fresh: clear any leftover findings from a previous session
  vim.fn.setqflist({}, "r", { title = "Review checkers", items = {} })
  build_ui(S)
  render_sidebar(S.sidebar_buf, S)
  -- No file is shown on open (empty placeholder) so nothing runs until selection.
  if vim.api.nvim_win_is_valid(S.sidebar_win) then
    vim.api.nvim_set_current_win(S.sidebar_win)
    pcall(vim.api.nvim_win_set_cursor, S.sidebar_win, { 5, 0 })
  end
end

-- Repo-relative path of the file whose diff buffer is `bufnr`, or nil.
function M.file_for(bufnr)
  if not S then return nil end
  for path, b in pairs(S.file_bufs or {}) do
    if b == bufnr then return path end
  end
  return nil
end

-- Describe a diff-buffer row range for external consumers (e.g. kitty_drop):
-- maps the selected rows back to SOURCE line numbers via the file's line map.
-- Returns { file = relpath, l1 = srcStart, l2 = srcEnd, lines = {selected diff lines} }
-- or nil if `bufnr` is not one of our diff buffers.
function M.context_for(bufnr, r1, r2)
  local path = M.file_for(bufnr)
  if not path then return nil end
  if r1 > r2 then r1, r2 = r2, r1 end
  local linemap = (S.linemaps or {})[path] or {}
  local lo, hi
  for src, row in pairs(linemap) do
    if row >= r1 and row <= r2 then
      lo = (not lo or src < lo) and src or lo
      hi = (not hi or src > hi) and src or hi
    end
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, r1 - 1, r2, false)
  return { file = path, l1 = lo, l2 = hi, lines = lines, ft = vim.bo[bufnr].filetype }
end

-- Revert the change under the cursor back to its base (develop) state: replace
-- the hunk's new lines with the base version (delete added lines / restore
-- deleted lines / swap changed lines), write the file, then refresh the overlay.
-- Modifies the working tree, so it asks for confirmation first.
function M.revert_under_cursor()
  if not S then return end
  local st = S
  local bufnr = vim.api.nvim_get_current_buf()
  local path = M.file_for(bufnr)
  if not path then
    vim.notify("review_view: cursor is not in a diff buffer", vim.log.levels.WARN)
    return
  end
  local entry = st.current_file
  local abspath = st.root .. "/" .. path
  if (entry and (entry.binary or entry.untracked)) or vim.fn.filereadable(abspath) ~= 1 then
    vim.notify("review_view: revert only supported for tracked text files", vim.log.levels.WARN)
    return
  end

  local L = vim.api.nvim_win_get_cursor(0)[1]
  local hunks = parse_hunks(st.root, st.merge_base, path)
  local hunk
  for _, h in ipairs(hunks) do            -- added / changed: cursor inside new range
    if h.nc > 0 and L >= h.nl and L <= h.nl + h.nc - 1 then hunk = h break end
  end
  if not hunk then
    for _, h in ipairs(hunks) do          -- pure deletion: cursor on the anchor line
      if h.nc == 0 and (L == h.nl or L == h.nl + 1) then hunk = h break end
    end
  end
  if not hunk then
    vim.notify("review_view: no change under the cursor to revert", vim.log.levels.INFO)
    return
  end

  local what
  if #hunk.removed == 0 then
    what = ("discard %d added line(s)"):format(hunk.nc)
  elseif hunk.nc == 0 then
    what = ("restore %d deleted line(s)"):format(#hunk.removed)
  else
    what = ("restore %d base line(s) over %d changed"):format(#hunk.removed, hunk.nc)
  end
  if vim.fn.confirm(("Revert this change to %s?\n  %s"):format(st.base or "base", what), "&Yes\n&No", 2) ~= 1 then
    return
  end

  local lines = vim.fn.readfile(abspath)
  local out = {}
  if hunk.nc == 0 then
    -- pure deletion: re-insert the base lines after the anchor line nl
    for k = 1, hunk.nl do out[#out + 1] = lines[k] end
    for _, rl in ipairs(hunk.removed) do out[#out + 1] = rl end
    for k = hunk.nl + 1, #lines do out[#out + 1] = lines[k] end
  else
    -- added / changed: replace the new lines [nl, nl+nc-1] with the base lines
    for k = 1, hunk.nl - 1 do out[#out + 1] = lines[k] end
    for _, rl in ipairs(hunk.removed) do out[#out + 1] = rl end
    for k = hunk.nl + hunk.nc, #lines do out[#out + 1] = lines[k] end
  end
  vim.fn.writefile(out, abspath)
  vim.cmd("checktime")                    -- reload the file if it's open elsewhere
  M.refresh()
  vim.notify("review_view: reverted change in " .. path, vim.log.levels.INFO)
end

-- Revert the WHOLE file under the cursor (in the sidebar) back to its base
-- (develop) state: restore the base content, or delete it if the file is new in
-- this branch. Confirms first since it discards every change in that file.
function M.revert_file_under_cursor()
  if not S then return end
  local st = S
  local e = entry_under_cursor()
  if not e then
    vim.notify("review_view: put the cursor on a file in the sidebar", vim.log.levels.WARN)
    return
  end
  local path = e.path
  local abspath = st.root .. "/" .. path

  vim.fn.systemlist({ "git", "-C", st.root, "cat-file", "-e", st.merge_base .. ":" .. path })
  local in_base = vim.v.shell_error == 0

  local what = in_base
    and ("discard ALL changes in " .. path)
    or ("delete new file " .. path)
  if vim.fn.confirm(("Revert whole file to %s?\n  %s"):format(st.base or "base", what), "&Yes\n&No", 2) ~= 1 then
    return
  end

  if not in_base then
    vim.fn.delete(abspath)                         -- new file: base had none
  elseif e.binary then
    vim.fn.systemlist({ "git", "-C", st.root, "checkout", st.merge_base, "--", path })
  else
    local content = vim.fn.systemlist({ "git", "-C", st.root, "show", st.merge_base .. ":" .. path })
    vim.fn.writefile(content, abspath)
  end
  vim.cmd("checktime")
  M.refresh()
  vim.notify("review_view: reverted file " .. path, vim.log.levels.INFO)
end

-- Open the real file shown in the current diff pane in a (reused) edit tab, at
-- the source line under the cursor. `gR` in that buffer saves and returns to the
-- review (refreshing the diff to reflect the edits).
function M.edit_under_cursor()
  if not S then return end
  local bufnr = vim.api.nvim_get_current_buf()
  local path = M.file_for(bufnr)
  if not path then
    vim.notify("review_view: cursor is not in a diff buffer", vim.log.levels.WARN)
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local srcline = src_for_row((S.linemaps or {})[path], row)
  local abspath = S.root .. "/" .. path

  -- reuse one edit tab so repeated edits don't pile up tabs
  if S.edit_tab and vim.api.nvim_tabpage_is_valid(S.edit_tab) then
    vim.api.nvim_set_current_tabpage(S.edit_tab)
    vim.cmd("edit " .. vim.fn.fnameescape(abspath))
  else
    vim.cmd("tabedit " .. vim.fn.fnameescape(abspath))
    S.edit_tab = vim.api.nvim_get_current_tabpage()
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { srcline, 0 })
  pcall(vim.cmd, "normal! zz")

  vim.keymap.set("n", "gR", function() M.edit_return(path) end, {
    buffer = vim.api.nvim_get_current_buf(), nowait = true, silent = true,
    desc = "Review: save & back to review",
  })
  vim.notify("review_view: editing " .. path .. "   (gR = save & back, gt = review tab)",
    vim.log.levels.INFO)
end

-- Save the edit buffer (if a real, modified file), close the edit tab, return to
-- the review tab, refresh the diffs and re-show the edited file's diff.
function M.edit_return(path)
  if vim.bo.buftype == "" and vim.bo.modifiable and not vim.bo.readonly and vim.bo.modified then
    pcall(vim.cmd, "write")
  end
  local review_tab = S and S.tabpage
  if S and S.edit_tab and vim.api.nvim_tabpage_is_valid(S.edit_tab)
      and #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, "tabclose")
    S.edit_tab = nil
  end
  if not S then return end
  if review_tab and vim.api.nvim_tabpage_is_valid(review_tab) then
    pcall(vim.api.nvim_set_current_tabpage, review_tab)
  end
  M.refresh()
  -- re-display the file we just edited, if it still has changes
  if path then
    for _, e in ipairs(S.files or {}) do
      if e.path == path then show_file(S, e); break end
    end
  end
end

-- Open a CodeCompanion chat seeded with the current review context: the file
-- under review, its diff, the checker findings, and commit subjects. opts.entry
-- overrides the file (e.g. the sidebar row under the cursor); opts.visual adds the
-- current visual selection as a focus block.
function M.codecompanion(opts)
  opts = opts or {}
  local st = S
  if not st then return end
  local cc_ok, cc = pcall(require, "codecompanion")
  if not cc_ok then
    vim.notify("review_view: CodeCompanion not available", vim.log.levels.WARN); return
  end
  local entry = opts.entry or st.current_file
  if not entry then
    vim.notify("review_view: select a file first (⏎)", vim.log.levels.WARN); return
  end
  local path = entry.path
  local rc = require("config.review_context")

  -- make sure the file's diff is computed/cached
  if not st.diffs[path] then ensure_file_buf(st, entry) end

  local parts = {}
  table.insert(parts, ("Reviewing `%s` (`%s` → working tree) in repo `%s`."):format(
    path, st.base, rc.repo_name(st.root)))

  local subjects = rc.format_subjects(rc.commit_subjects(st.root, st.merge_base, "HEAD", 30))
  if subjects then
    table.insert(parts, ""); table.insert(parts, "Commits in this range:"); table.insert(parts, subjects)
  end

  local findings = {}
  for _, it in ipairs(st.items) do
    if it._file == path then findings[#findings + 1] = ("- line %d: %s"):format(it.lnum, it.text) end
  end
  if #findings > 0 then
    table.insert(parts, ""); table.insert(parts, "Checker findings for this file:")
    vim.list_extend(parts, findings)
  end

  local diff = st.diffs[path]
  if diff and vim.trim(diff) ~= "" then
    table.insert(parts, ""); table.insert(parts, "Diff:")
    table.insert(parts, "```diff"); table.insert(parts, diff); table.insert(parts, "```")
  end

  if opts.visual then
    local buf = vim.api.nvim_get_current_buf()
    local l1, l2 = vim.fn.getpos("'<")[2], vim.fn.getpos("'>")[2]
    if l1 > 0 and l2 > 0 then
      if l1 > l2 then l1, l2 = l2, l1 end
      local ctx = M.context_for(buf, l1, l2)
      local lines = (ctx and ctx.lines) or vim.api.nvim_buf_get_lines(buf, l1 - 1, l2, false)
      local ft = (ctx and ctx.ft) or vim.bo[buf].filetype or ""
      table.insert(parts, "")
      table.insert(parts, ("Focus on lines %d-%d:"):format((ctx and ctx.l1) or l1, (ctx and ctx.l2) or l2))
      table.insert(parts, "```" .. ft); table.insert(parts, table.concat(lines, "\n")); table.insert(parts, "```")
    end
  end

  table.insert(parts, "")
  local chat = cc.chat({ messages = { { role = "user", content = table.concat(parts, "\n") } }, auto_submit = false })
  vim.schedule(function()
    if chat and chat.ui and chat.ui.win and vim.api.nvim_win_is_valid(chat.ui.win) then
      vim.api.nvim_set_current_win(chat.ui.win)
    end
    vim.cmd("startinsert")
  end)
end

-- nvim-tree entry point: open for the node under the cursor.
function M.open_from_node(node)
  if node and node.absolute_path then M.open(node.absolute_path) end
end

return M
