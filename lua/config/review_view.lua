-- review_view: a small standalone patch-review screen (separate from diffview).
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
  vim.api.nvim_set_hl(0, "ReviewViewDir", { link = "Directory" })
  vim.api.nvim_set_hl(0, "ReviewViewAdd", { link = "diffAdded" })
  vim.api.nvim_set_hl(0, "ReviewViewDel", { link = "diffRemoved" })
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

-- Build the changed-file list from numstat (adds, dels, path) over <base>...HEAD.
local function collect_files(root, base, head)
  local ok, out = git(root, { "diff", "--numstat", base .. "..." .. head })
  if not ok then return {} end
  local files = {}
  for _, line in ipairs(out) do
    local adds, dels, path = line:match("^(%S+)\t(%S+)\t(.+)$")
    if path then
      -- renames render as "old => new" or "{a => b}/x"; keep the raw string for display
      local binary = (adds == "-" or dels == "-")
      table.insert(files, {
        path = path,
        adds = binary and 0 or tonumber(adds) or 0,
        dels = binary and 0 or tonumber(dels) or 0,
        binary = binary,
      })
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

  table.insert(lines, ("%s ...%s  (%d files)"):format(st.base, st.head_ref, #st.files))
  table.insert(lines, "r=review ⏎=open Tab=fold zM/zR=all q=close")
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
        local row_text = string.rep(" ", indent) .. fit(name, namew) .. " "
          .. string.rep(" ", math.max(0, countw - #counts)) .. counts
        table.insert(lines, row_text)
        line_index[#lines] = f
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
  vim.keymap.set("n", "]q", "<cmd>cnext<cr>", o)
  vim.keymap.set("n", "[q", "<cmd>cprev<cr>", o)
  vim.keymap.set("n", "q", function() M.close() end, o)
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

-- Build (and cache) the red/green diff buffer for one file, plus its line map.
-- Returns bufnr, diff_text, linemap.
local function ensure_file_buf(st, entry)
  local path = entry.path
  local cached = st.file_bufs[path]
  if cached and vim.api.nvim_buf_is_valid(cached) then
    return cached, st.diffs[path], st.linemaps[path]
  end

  local rc = require("config.review_context")
  local diff = rc.diff(st.root, st.merge_base, "HEAD", path, {}) or ""
  if vim.trim(diff) == "" then diff = "(no diff for " .. path .. ")" end
  local diff_lines = vim.split(diff, "\n", { plain = true })

  -- new-file-line -> row map
  local linemap, newln = {}, nil
  for i, line in ipairs(diff_lines) do
    local hh = line:match("^@@ %-%d+,?%d* %+(%d+)")
    if hh then
      newln = tonumber(hh)
    elseif newln then
      local c = line:sub(1, 1)
      if line:match("^%+%+%+") or line:match("^%-%-%-") then
        -- file header inside diff; ignore
      elseif c == "+" or c == " " then
        linemap[newln] = i; newln = newln + 1
      end
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = "diff"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, diff_lines)
  vim.bo[buf].modifiable = false

  -- light red/green line backgrounds
  for i, line in ipairs(diff_lines) do
    local c = line:sub(1, 1)
    if line:match("^%+%+%+") or line:match("^%-%-%-") then
      -- header, no bg
    elseif c == "+" then
      vim.api.nvim_buf_set_extmark(buf, HL_NS, i - 1, 0, { line_hl_group = "ReviewViewAddLine" })
    elseif c == "-" then
      vim.api.nvim_buf_set_extmark(buf, HL_NS, i - 1, 0, { line_hl_group = "ReviewViewDelLine" })
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
  vim.fn.setqflist({}, "r", { title = "Review checkers", items = st.items })
  local by_buf = {}
  for _, it in ipairs(st.items) do
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
  if st.inflight[path] and not opts.force then return end
  if st.done[path] and not opts.force then return end

  local buf, diff, linemap = ensure_file_buf(st, entry)
  show_file(st, entry)

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
  table.insert(pparts, "```diff"); table.insert(pparts, pdiff); table.insert(pparts, "```")
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
          local _, lnum, msg = line:match("^LOC:%s*([^:]+):(%d+)%s+(.+)")
          if not (lnum and msg) then return end
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
                vim.cmd("copen")
                if vim.api.nvim_win_is_valid(st.diff_win) then vim.api.nvim_set_current_win(st.diff_win) end
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
    "", "  Select a file (⏎) to view its diff and run the checkers.", "",
    "  r = re-run checkers   ]q/[q = navigate findings",
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
    -- On a folder header: fold/unfold. On a file: show diff + run all checkers.
    if toggle_fold(st) then return end
    local e = entry_under_cursor()
    if e then run_checkers(st, e) end
  end, o)
  vim.keymap.set("n", "r", function()
    local e = entry_under_cursor()
    if e then run_checkers(st, e, { force = true }) end
  end, o)
  vim.keymap.set("n", "<Tab>", function() toggle_fold(st) end, o)
  vim.keymap.set("n", "za", function() toggle_fold(st) end, o)
  vim.keymap.set("n", "zM", function() fold_all(st, true) end, o)
  vim.keymap.set("n", "zR", function() fold_all(st, false) end, o)
  vim.keymap.set("n", "q", M.close, o)
  vim.keymap.set("n", "]q", "<cmd>cnext<cr>", o)
  vim.keymap.set("n", "[q", "<cmd>cprev<cr>", o)
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

  local files = collect_files(root, base, head_ref)
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
    pcall(vim.api.nvim_win_set_cursor, S.sidebar_win, { 4, 0 })
  end
end

-- nvim-tree entry point: open for the node under the cursor.
function M.open_from_node(node)
  if node and node.absolute_path then M.open(node.absolute_path) end
end

return M
