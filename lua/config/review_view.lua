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

local MAX_DIFF_CHARS = 16000
local NS = vim.api.nvim_create_namespace("review_view")          -- diagnostics
local HL_NS = vim.api.nvim_create_namespace("review_view_hl")    -- +/- line backgrounds
local SIDE_NS = vim.api.nvim_create_namespace("review_view_side") -- sidebar headers/counts
local DEL_NS = vim.api.nvim_create_namespace("review_view_del")  -- deleted-line virt_lines (repainted on show)
local SIDEBAR_WIDTH = 42
-- Sentinel "directory" key for the collapsible Commits section (reuses the fold
-- machinery in dir_index / st.collapsed without colliding with a real dir name).
local COMMITS_KEY = "\1commits"

-- Subtle full-line backgrounds for added/removed lines, layered over filetype=diff
-- foreground coloring. Re-applied on ColorScheme so it survives theme changes.
local function ensure_hl()
  local dark = vim.o.background == "dark"
  -- Dim shades = changes already pushed to the remote feature branch (@{u}).
  vim.api.nvim_set_hl(0, "ReviewViewAddLine", { bg = dark and "#16291d" or "#e6ffec" })
  vim.api.nvim_set_hl(0, "ReviewViewDelLine", { bg = dark and "#33181b" or "#ffebe9" })
  vim.api.nvim_set_hl(0, "ReviewViewChangeLine", { bg = dark and "#33301a" or "#fff5b1" })
  -- Vivid shades = unpushed changes (new since the last push, incl. uncommitted).
  vim.api.nvim_set_hl(0, "ReviewViewAddLineNew", { bg = dark and "#1f5233" or "#acf2bd" })
  vim.api.nvim_set_hl(0, "ReviewViewDelLineNew", { bg = dark and "#5c1f24" or "#ffc1bc" })
  vim.api.nvim_set_hl(0, "ReviewViewChangeLineNew", { bg = dark and "#4d4713" or "#ffdf5d" })
  vim.api.nvim_set_hl(0, "ReviewViewDir", { link = "Directory" })
  vim.api.nvim_set_hl(0, "ReviewViewTicket", { link = "Question" })
  vim.api.nvim_set_hl(0, "ReviewViewAdd", { link = "diffAdded" })
  vim.api.nvim_set_hl(0, "ReviewViewDel", { link = "diffRemoved" })
  vim.api.nvim_set_hl(0, "ReviewViewDirty", { link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "ReviewViewNew", { fg = dark and "#3fb950" or "#1a7f37", bold = true })
end
ensure_hl()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("ReviewViewHL", { clear = true }),
  callback = ensure_hl,
})

local REVIEW_PROMPT = [[Review this diff for bugs, type errors, logic errors, security issues.
First infer the change's intent from the commit subjects and the diff itself. Then
interrogate the motivation behind each change: does it actually advance that intent,
or is it incidental? Flag changes that don't matter — no observable effect on behavior,
output, or correctness; churn that could be dropped with no loss; speculative handling
for cases that cannot occur here; or complexity added for a problem the code doesn't have.
Also flag any added/changed line that does not serve the change's purpose — dead code,
unused variables, redundant reimplementations of existing helpers, gratuitous refactors,
or edits unrelated to the task.
Also check comments: flag any that are inaccurate or misleading about what the code actually does,
contain outdated history or change-log notes that belong in git commit messages instead,
or describe unrelated concerns irrelevant to the surrounding block.
Also check that every added/changed comment is compact and precise: flag comments that are
verbose, over-explain the obvious, restate the code, or could be cut to one tight line.
Each added/context line in the diff is prefixed with its line number and a TAB
(e.g. "188\t+ ..."). Use that exact prefixed number as <line_number> — do not
count lines yourself. Only report on lines that have a number.
For each issue output exactly ONE line:
LOC: <file_path>:<line_number> <brief description>
After all issues: one-sentence summary. No other text.]]

-- Any number of reviews can be open at once, one per tabpage. `reviews` maps a
-- tabpage id to its state; `S` is whichever review tab is currently active. sync()
-- refreshes `S` from the current tabpage at each entry point, so all the S.*
-- handlers act on the review you're actually looking at.
local reviews = {}
local S = nil

local function sync()
  S = reviews[vim.api.nvim_get_current_tabpage()]
  return S
end

-- Is `st` still an open review? Guards late async checker callbacks whose review
-- may have been closed (or which fire while a different tab is active).
local function is_live(st)
  for _, r in pairs(reviews) do if r == st then return true end end
  return false
end

-- The review that owns diff buffer `bufnr`, or nil — used by buf-addressed calls
-- (file_for/context_for) that may run for a buffer outside the current tab.
local function review_for_buf(bufnr)
  for _, r in pairs(reviews) do
    for _, b in pairs(r.file_bufs or {}) do
      if b == bufnr then return r end
    end
  end
end

-- A buffer name unique among existing buffers, so two reviews of the same repo
-- (or the same file) don't collide when we name their buffers for the tabline.
local function unique_bufname(base)
  if vim.fn.bufexists(base) == 0 then return base end
  local i = 2
  while vim.fn.bufexists(base .. " (" .. i .. ")") == 1 do i = i + 1 end
  return base .. " (" .. i .. ")"
end

-- The quickfix is a single shared list, so make it follow the active review: when
-- you enter a review tab, load that review's findings into the quickfix.
vim.api.nvim_create_autocmd("TabEnter", {
  group = vim.api.nvim_create_augroup("ReviewViewTab", { clear = true }),
  callback = function()
    local st = reviews[vim.api.nvim_get_current_tabpage()]
    if st then
      S = st
      vim.fn.setqflist({}, "r", { title = "Review checkers", items = st.items or {} })
    end
  end,
})

local function git(root, args)
  local cmd = { "git", "-C", root }
  vim.list_extend(cmd, args)
  local out = vim.fn.systemlist(cmd)
  return vim.v.shell_error == 0, out
end

-- The remote to fetch/push against. Configurable via settings_local.git_remote.
local function remote_name()
  local ok, sl = pcall(require, "config.settings_local")
  return (ok and type(sl) == "table" and sl.git_remote) or "origin"
end

-- Ahead/behind of HEAD vs its upstream (the REMOTE feature branch, e.g.
-- origin/my-feature) — i.e. whether local commits need pushing (ahead) or the
-- remote has commits to pull (behind). No network: compares against the last-known
-- remote-tracking ref, so "to push" is always accurate; "to pull" may be stale
-- until a fetch (gf).
local function upstream_status(root)
  local uok, uout = git(root, { "rev-parse", "--abbrev-ref", "@{u}" })
  local name = (uok and uout[1] and uout[1] ~= "") and uout[1] or nil
  if not name then return { has_upstream = false } end
  local ok, out = git(root, { "rev-list", "--left-right", "--count", "@{u}...HEAD" })
  local behind, ahead = 0, 0
  if ok and out[1] then behind, ahead = out[1]:match("(%d+)%s+(%d+)") end
  return { has_upstream = true, name = name, behind = tonumber(behind) or 0, ahead = tonumber(ahead) or 0 }
end

-- Mirror of tree.lua resolve_base: try git_base, then main/master/develop and
-- their origin/ variants, finally origin/HEAD.
local function resolve_base(root)
  local ok, settings_local = pcall(require, "config.settings_local")
  local git_base = (ok and type(settings_local) == "table" and settings_local.git_base_branch) or "main"
  local remote = remote_name()
  local function verify(ref)
    vim.fn.systemlist({ "git", "-C", root, "rev-parse", "--verify", "--quiet", ref })
    return vim.v.shell_error == 0
  end
  local candidates = { git_base, remote .. "/" .. git_base }
  for _, b in ipairs({ "main", "master", "develop" }) do
    if b ~= git_base then
      table.insert(candidates, b)
      table.insert(candidates, remote .. "/" .. b)
    end
  end
  for _, c in ipairs(candidates) do
    if verify(c) then return c, git_base end
  end
  local okh, out = git(root, { "symbolic-ref", "--short", "refs/remotes/" .. remote .. "/HEAD" })
  if okh and out[1] and out[1] ~= "" then return out[1], git_base end
  return nil, git_base
end

-- Human repo name: the origin project name (works even for a temp worktree whose
-- toplevel dir is a random tempname), falling back to the root's basename.
local function repo_name(root)
  local ok, url = git(root, { "remote", "get-url", remote_name() })
  if ok and url[1] and url[1] ~= "" then
    local n = url[1]:gsub("%.git$", ""):match("([^/:]+)$")
    if n and n ~= "" then return n end
  end
  return vim.fn.fnamemodify(root, ":t")
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
-- tagged committed / dirty / untracked / unpushed so the sidebar can differentiate.
-- `pushed_ref` is the remote feature branch (@{u}) sha, or nil when the branch has
-- no upstream — then nothing is "pushed" so the distinction is skipped.
local function collect_files(root, base, merge_base, head, pushed_ref)
  -- which files have committed changes (base...HEAD) vs uncommitted (vs HEAD)
  local committed = name_set(root, { "diff", "--name-only", base .. "..." .. head })
  local dirty     = name_set(root, { "diff", "--name-only", "HEAD" })
  -- which files carry changes not yet on the remote feature branch (@{u}..working-tree)
  local unpushed  = pushed_ref and name_set(root, { "diff", "--name-only", pushed_ref }) or {}

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
          unpushed = unpushed[path] or false,
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
        files[#files + 1] = { path = path, adds = 0, dels = 0, untracked = true, dirty = true, unpushed = true }
        seen[path] = true
      end
    end
  end
  table.sort(files, function(a, b) return a.path < b.path end)
  return files
end

-- Changed-file list for a CHECKPOINT view: the plain left..right commit diff,
-- with no working-tree notions (dirty/untracked/unpushed). Every entry is
-- "committed" — it's a historical snapshot, not the live tree.
local function collect_files_at(root, left, right)
  local files = {}
  local ok, out = git(root, { "diff", "--numstat", left, right })
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
          committed = true,
        }
      end
    end
  end
  table.sort(files, function(a, b) return a.path < b.path end)
  return files
end

-- The branch's commits (left..HEAD), newest first — the checkpoints you can browse.
-- Each entry: { sha = full, short = abbrev, subject = %s }.
local function list_commits(root, left, head, limit)
  local commits = {}
  local ok, out = git(root, { "log", ("--format=%%H%s%%h%s%%s"):format("\31", "\31"),
    ("-n%d"):format(limit or 200), left .. ".." .. head })
  if ok then
    for _, line in ipairs(out) do
      local sha, short, subject = line:match("^([^\31]+)\31([^\31]+)\31(.*)$")
      if sha then commits[#commits + 1] = { sha = sha, short = short, subject = subject } end
    end
  end
  return commits
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

  table.insert(lines, " " .. (st.repo or "?"))
  table.insert(hi, { row = #lines - 1, kind = "repo" })
  local right_label = st.view_ref
    and (st.view_single and ("commit @" .. st.view_short) or ("@" .. st.view_short))
    or st.head_ref
  table.insert(lines, ("%s → %s  (%d files)"):format(st.base, right_label, #st.files))
  -- Checkpoint banner: which commit we're viewing "as if it were HEAD", and how to leave.
  if st.view_ref then
    local mode = st.view_single and "this commit only" or "as if it were HEAD"
    table.insert(lines, ("⟳ viewing @%s (%s)  ·  gh = live"):format(st.view_short, mode))
    table.insert(hi, { row = #lines - 1, kind = "line", hl = "DiagnosticWarn" })
  end
  -- vs the remote feature branch: spell out push/pull so the arrows aren't cryptic
  local u = st.upstream
  if u and not st.view_ref then
    local text, ehl
    if not u.has_upstream then
      text, ehl = "⚠ not pushed yet — no remote branch", "DiagnosticWarn"
    elseif u.ahead > 0 and u.behind > 0 then
      text = ("↑%d to push  ↓%d to pull  (diverged from %s)"):format(u.ahead, u.behind, u.name)
      ehl = "DiagnosticWarn"
    elseif u.ahead > 0 then
      text = ("↑ %d commit%s to push → %s"):format(u.ahead, u.ahead == 1 and "" or "s", u.name)
      ehl = "DiagnosticWarn"
    elseif u.behind > 0 then
      text = ("↓ %d commit%s to pull ← %s"):format(u.behind, u.behind == 1 and "" or "s", u.name)
      ehl = "DiagnosticInfo"
    else
      text, ehl = ("✓ in sync with %s"):format(u.name), "DiagnosticOk"
    end
    table.insert(lines, text)
    table.insert(hi, { row = #lines - 1, kind = "line", hl = ehl })
  end
  if not st.view_ref then
    table.insert(lines, "↑ unpushed  ● uncommitted  + new")
  end
  table.insert(lines, "? help   q quit   R reload   C chat")
  table.insert(lines, "")

  -- Jira ticket node (selectable): loaded async by load_ticket() on open/refresh.
  if st.ticket then
    table.insert(lines, fit(("📋 %s  %s"):format(st.ticket.key, st.ticket.summary), width - 1))
    line_index[#lines] = { ticket = true }
    table.insert(hi, { row = #lines - 1, kind = "ticket" })
    table.insert(lines, "")
  end

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
        -- status marker (most-specific state wins): + new (untracked), ● uncommitted
        -- (dirty), ↑ committed-but-unpushed, blank = committed and already pushed
        local mk, mk_hl = " ", nil
        if f.untracked then mk, mk_hl = "+", "ReviewViewAdd"
        elseif f.dirty then mk, mk_hl = "●", "ReviewViewDirty"
        elseif f.unpushed then mk, mk_hl = "↑", "ReviewViewNew" end
        -- ◆ in the gutter (col 0) marks the file currently shown in the diff pane —
        -- mirrors the ◆/● active-row marker in the Commits section. The git-status
        -- marker keeps its column, just shifted right by the (fixed-width) gutter.
        local curmk = (st.current_file and st.current_file.path == f.path) and "◆" or " "
        local prefix = curmk .. " " .. mk .. " "   -- gutter mark + space + status marker + space (width 4)
        local row_text = prefix .. fit(name, namew) .. " "
          .. string.rep(" ", math.max(0, countw - #counts)) .. counts
        table.insert(lines, row_text)
        line_index[#lines] = f
        if curmk ~= " " then
          table.insert(hi, { row = #lines - 1, kind = "mark", a = 0, b = #curmk, hl = "ReviewViewNew" })
        end
        if mk_hl then
          local mstart = #curmk + 1   -- byte offset of the status marker (after gutter + space)
          table.insert(hi, { row = #lines - 1, kind = "mark", a = mstart, b = mstart + #mk, hl = mk_hl })
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

  -- Commits section (collapsible), below the file tree: browse each commit as a
  -- checkpoint. ⏎ shows the branch as it stood at that commit; s shows only what
  -- that one commit changed.
  if st.commits and #st.commits > 0 then
    local collapsed = st.collapsed[COMMITS_KEY]
    table.insert(lines, "")
    table.insert(lines, ("%s Commits  (%d)  ⏎ checkpoint · s single"):format(
      collapsed and "▸" or "▾", #st.commits))
    dir_index[#lines] = COMMITS_KEY
    table.insert(hi, { row = #lines - 1, kind = "dir" })
    if not collapsed then
      -- live / working-tree row: return to the normal (HEAD + uncommitted) view
      local active = not st.view_ref
      table.insert(lines, ("  %s working tree (live)"):format(active and "◆" or " "))
      line_index[#lines] = { live = true }
      if active then table.insert(hi, { row = #lines - 1, kind = "mark", a = 2, b = 2 + #"◆", hl = "ReviewViewNew" }) end
      for _, c in ipairs(st.commits) do
        local cur = st.view_ref == c.sha
        local mk = cur and "●" or " "
        local prefix = "  " .. mk .. " "   -- 2 spaces + marker + space (marker may be multibyte)
        local text = fit(prefix .. c.short .. " " .. (c.subject or ""), width - 1)
        table.insert(lines, text)
        line_index[#lines] = { commit = c.sha, short = c.short }
        if cur then table.insert(hi, { row = #lines - 1, kind = "mark", a = 2, b = 2 + #mk, hl = "ReviewViewNew" }) end
        table.insert(hi, { row = #lines - 1, kind = "commitsha", a = #prefix, b = #prefix + #c.short })
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
    elseif h.kind == "repo" then
      vim.api.nvim_buf_set_extmark(buf, SIDE_NS, h.row, 0, { end_row = h.row + 1, hl_group = "Title" })
    elseif h.kind == "add" then
      vim.api.nvim_buf_set_extmark(buf, SIDE_NS, h.row, h.a, { end_col = h.b, hl_group = "ReviewViewAdd" })
    elseif h.kind == "del" then
      vim.api.nvim_buf_set_extmark(buf, SIDE_NS, h.row, h.a, { end_col = h.b, hl_group = "ReviewViewDel" })
    elseif h.kind == "mark" then
      vim.api.nvim_buf_set_extmark(buf, SIDE_NS, h.row, h.a, { end_col = h.b, hl_group = h.hl })
    elseif h.kind == "line" then
      vim.api.nvim_buf_set_extmark(buf, SIDE_NS, h.row, 0, { end_row = h.row + 1, hl_group = h.hl })
    elseif h.kind == "ticket" then
      vim.api.nvim_buf_set_extmark(buf, SIDE_NS, h.row, 0, { end_row = h.row + 1, hl_group = "ReviewViewTicket" })
    elseif h.kind == "commitsha" then
      vim.api.nvim_buf_set_extmark(buf, SIDE_NS, h.row, h.a, { end_col = h.b, hl_group = "Comment" })
    end
  end

  st.line_index = line_index
  st.dir_index = dir_index
end

-- Locate a Universal Ctags binary. On macOS /usr/bin/ctags (BSD) shadows the
-- Homebrew one in PATH, so probe explicit locations and verify the flavour.
local _ctags_bin
local function ctags_bin()
  if _ctags_bin ~= nil then return _ctags_bin or nil end
  local cands = {
    "/opt/homebrew/bin/ctags", "/opt/homebrew/opt/universal-ctags/bin/ctags",
    "/usr/local/bin/ctags", "/usr/local/opt/universal-ctags/bin/ctags", "ctags",
  }
  for _, c in ipairs(cands) do
    if vim.fn.executable(c) == 1 then
      local v = vim.system({ c, "--version" }, { text = true }):wait()
      if v.code == 0 and (v.stdout or ""):match("Universal Ctags") then
        _ctags_bin = c; return c
      end
    end
  end
  _ctags_bin = false
  return nil
end

-- Where the repo's tags file lives (per-repo, in the cache dir).
local function tags_path(root)
  local dir = vim.fn.stdpath("cache") .. "/review_view"
  vim.fn.mkdir(dir, "p")
  return dir .. "/" .. root:gsub("[^%w]", "_") .. ".tags"
end

-- (Re)generate the tags file for the review's repo, asynchronously. Absolute paths
-- (--tag-relative=never) so tag lookups resolve from any buffer/cwd. Silent no-op
-- if Universal Ctags isn't installed — tag jumps just won't resolve.
local function ensure_tags(st, force)
  if not st or not st.tags_file then return end
  local ctags = ctags_bin()
  if not ctags then return end
  if not force and vim.fn.filereadable(st.tags_file) == 1 then return end
  -- ctags refuses to overwrite a target that "doesn't look like a tag file" — e.g.
  -- an empty/garbage file left by an interrupted or killed run. We always regenerate,
  -- so remove any existing target first; ctags then writes a fresh file with no refusal.
  vim.fn.delete(st.tags_file)
  vim.system({ ctags, "-R", "--tag-relative=never", "--fields=+n", "--exclude=.git",
    "-f", st.tags_file, st.root }, { text = true }, vim.schedule_wrap(function(res)
    if res.code ~= 0 then
      vim.notify("review_view: ctags failed: " .. (res.stderr or ""), vim.log.levels.WARN)
    end
  end))
end

-- Manually rebuild the tags index (bound to gT-adjacent workflows / :lua if needed).
function M.retag()
  if not sync() then return end
  ensure_tags(S, true)
  vim.notify("review_view: rebuilding tags…", vim.log.levels.INFO)
end

local function new_scratch(ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  if ft then vim.bo[buf].filetype = ft end
  -- Point tag lookups (<C-]>, g], :tag) at the repo's ctags file so definition
  -- jumps work natively from the diff panes (which are scratch buffers).
  if S and S.tags_file then pcall(function() vim.bo[buf].tags = S.tags_file end) end
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
  -- Definition jump via the ctags file (set on the buffer in new_scratch). <C-]>,
  -- g], :tag and <C-t> all work natively; gd/]d are convenience aliases.
  vim.keymap.set("n", "gd", "<C-]>", { buffer = buf, nowait = true, silent = true, desc = "Review: go to definition" })
  vim.keymap.set("n", "]d", "<C-]>", { buffer = buf, nowait = true, silent = true, desc = "Review: go to definition" })
  vim.keymap.set("n", "r", function() M.run_checkers_current() end, o)
  vim.keymap.set("n", "P", function() M.push() end, o)
  vim.keymap.set("n", "B", function() M.rebase() end, o)
  vim.keymap.set("n", "gJ", function() M.open_ticket() end, o)
  vim.keymap.set("n", "gh", function() M.view_live() end, o)
  vim.keymap.set("n", "X", function() M.revert_under_cursor() end, o)
  -- J/K step files, U/D step commits — so you can flip through the review without
  -- leaving the diff pane (read-only, so these safely shadow join/undo/delete).
  vim.keymap.set("n", "J", function() M.step_file(1) end, o)
  vim.keymap.set("n", "K", function() M.step_file(-1) end, o)
  vim.keymap.set("n", "U", function() M.step_commit(-1) end, o)
  vim.keymap.set("n", "D", function() M.step_commit(1) end, o)
  vim.keymap.set("n", "?", function() M.show_help() end, o)
  vim.keymap.set("n", "q", function() M.close() end, o)
end

-- Re-display the help/cheatsheet (the placeholder buffer) in the diff pane.
function M.show_help()
  sync()
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

-- Classify per-line diff status of `path` between `left` and `right` (via -U0):
--   added[n]=true (green), changed[n]=true (yellow)  — n is a line in the RIGHT side,
--   dels = { { line=n, above=bool, lines={removed text} } }  (red, shown as virt lines)
-- `right` nil ⇒ the working tree (live view); a commit sha ⇒ that checkpoint.
local function diff_status(root, left, right, path)
  local added, changed, dels = {}, {}, {}
  local cmd = { "git", "-C", root, "diff", "-U0", left }
  if right then cmd[#cmd + 1] = right end
  vim.list_extend(cmd, { "--", path })
  local dl = vim.fn.systemlist(cmd)
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

-- Parse the left→right diff for `path` into hunks, keeping each hunk's new-file
-- range (nl .. nl+nc-1) and its removed (base/develop) lines, so a single change
-- can be reverted to its base state. `right` nil ⇒ working tree (live view).
local function parse_hunks(root, left, right, path)
  local cmd = { "git", "-C", root, "diff", "-U0", left }
  if right then cmd[#cmd + 1] = right end
  vim.list_extend(cmd, { "--", path })
  local dl = vim.fn.systemlist(cmd)
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

  -- The diff to render/paint: left..right, where `right` is the working tree in the
  -- live view (st.view_ref nil) or the selected commit when browsing a checkpoint,
  -- and `left` is the merge-base (checkpoint = "as if HEAD") or the commit's parent
  -- (single-commit view).
  local right = st.view_ref
  local left = st.view_left or st.merge_base

  -- the real unified diff is kept for the checker prompt regardless of how we render
  local diff
  if entry.untracked then
    diff = table.concat(vim.fn.systemlist({
      "git", "-C", st.root, "diff", "--no-index", "--", "/dev/null", path,
    }), "\n")
  elseif right then
    diff = rc.diff(st.root, left, right, path) or ""
  else
    diff = rc.diff(st.root, left, nil, path, { right_is_local = true }) or ""
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  -- Point tag lookups (<C-]>, g], gd/]d) at the repo's ctags file. This buffer is
  -- created directly (not via new_scratch), so it needs the tags option set here too.
  if st.tags_file then pcall(function() vim.bo[buf].tags = st.tags_file end) end
  -- Name it after the file so the tab label shows the filename (not "[Scratch]")
  -- when the diff pane is focused. The scheme keeps it distinct from real files.
  pcall(vim.api.nvim_buf_set_name, buf, unique_bufname("review://" .. st.repo .. "/" .. path))

  local linemap = {}
  -- Buffer content = the RIGHT side of the diff: the on-disk file (live), or the
  -- file as it stood at the checkpoint commit (`git show <sha>:<path>`). A file
  -- deleted at that commit has no blob → fall through to the unified-diff view.
  local content, readable
  local absent_at_commit = false   -- checkpoint view: file has no blob at the commit
  if right and not entry.untracked then
    local blob = vim.fn.systemlist({ "git", "-C", st.root, "show", right .. ":" .. path })
    if vim.v.shell_error == 0 and not entry.binary then
      content, readable = blob, true
    elseif vim.v.shell_error ~= 0 then
      absent_at_commit = true
    end
  else
    readable = vim.fn.filereadable(abspath) == 1 and not entry.binary
    if readable then content = vim.fn.readfile(abspath) end
  end

  if readable then
    -- FULL FILE + diff overlay
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
      added, changed, dels = diff_status(st.root, left, right, path)
    end

    -- Second pass vs the remote feature branch (@{u}) tells which of the above
    -- changes are UNPUSHED (new since the last push). Those get vivid shades so
    -- the last commit's work stands out from already-pushed changes (dim shades).
    -- Untracked files are entirely unpushed; skipped when browsing a checkpoint
    -- (a historical snapshot has no live pushed/unpushed distinction).
    local n_added, n_changed, n_dels = {}, {}, {}
    if not right and st.pushed_ref and not entry.untracked then
      n_added, n_changed, n_dels = diff_status(st.root, st.pushed_ref, nil, path)
    end
    local new_del_anchor = {}
    for _, d in ipairs(n_dels) do new_del_anchor[d.line] = true end
    local function line_is_new(n)
      if entry.untracked then return true end
      return (n_added[n] or n_changed[n]) and true or false
    end

    for n in pairs(added) do
      if n >= 1 and n <= #content then
        local hl = line_is_new(n) and "ReviewViewAddLineNew" or "ReviewViewAddLine"
        vim.api.nvim_buf_set_extmark(buf, HL_NS, n - 1, 0, { line_hl_group = hl })
      end
    end
    for n in pairs(changed) do
      if n >= 1 and n <= #content then
        local hl = line_is_new(n) and "ReviewViewChangeLineNew" or "ReviewViewChangeLine"
        vim.api.nvim_buf_set_extmark(buf, HL_NS, n - 1, 0, { line_hl_group = hl })
      end
    end
    -- Deleted lines render as virt_lines, which start at screen column 0 with no
    -- number/sign/fold gutter of their own — so they must be padded by the window's
    -- gutter width to line up under the code. That width isn't known until the
    -- buffer is shown (and grows when checker findings add signs), so stash the del
    -- data here and let paint_dels() draw it with the live gutter width at show time.
    local del_data = {}
    for _, d in ipairs(dels) do
      local is_new = entry.untracked or new_del_anchor[d.line] or false
      del_data[#del_data + 1] = {
        row = math.max(0, (d.line == 0 and 1 or d.line) - 1),
        above = d.above or d.line == 0,
        lines = d.lines,
        dhl = is_new and "ReviewViewDelLineNew" or "ReviewViewDelLine",
      }
    end
    st.dels[path] = del_data
  elseif absent_at_commit then
    -- Browsing a checkpoint where this file simply does not exist yet (or was
    -- removed by that commit): nothing to diff, so say so instead of a blank pane.
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "",
      ("  no file in the commit @%s"):format(st.view_short or right:sub(1, 8)),
      ("  (%s)"):format(path),
    })
    vim.bo[buf].modifiable = false
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

-- (Re)draw the stashed deleted-line virt_lines for `path`, padded to the diff
-- window's CURRENT gutter width (getwininfo.textoff = number+sign+fold columns) so
-- the removed code aligns under the numbered content. Own namespace so it can be
-- cleared/redrawn on every show without disturbing the +/- line backgrounds.
local function paint_dels(st, path)
  local buf = st.file_bufs[path]
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  vim.api.nvim_buf_clear_namespace(buf, DEL_NS, 0, -1)
  local data = st.dels and st.dels[path]
  if not data or #data == 0 then return end
  local pad = ""
  if vim.api.nvim_win_is_valid(st.diff_win) then
    local wi = vim.fn.getwininfo(st.diff_win)[1]
    if wi and wi.textoff and wi.textoff > 0 then pad = string.rep(" ", wi.textoff) end
  end
  for _, d in ipairs(data) do
    local virt = {}
    for _, rl in ipairs(d.lines) do virt[#virt + 1] = { { pad .. rl, d.dhl } } end
    vim.api.nvim_buf_set_extmark(buf, DEL_NS, d.row, 0, { virt_lines = virt, virt_lines_above = d.above })
  end
end

-- Display a file's diff in the right pane (no checker run).
local function show_file(st, entry)
  if not entry then return end
  local buf = ensure_file_buf(st, entry)
  st.current_file = entry
  if vim.api.nvim_win_is_valid(st.diff_win) then
    vim.api.nvim_win_set_buf(st.diff_win, buf)
    pcall(vim.api.nvim_win_set_cursor, st.diff_win, { 1, 0 })
    paint_dels(st, entry.path)   -- gutter width is known now the buffer is in the window
  end
  -- keep the ◆ current-file marker in the sidebar tracking the shown file
  if st.sidebar_buf and vim.api.nvim_buf_is_valid(st.sidebar_buf) then
    render_sidebar(st.sidebar_buf, st)
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
  if not is_live(st) then return end   -- review was closed: ignore late callbacks
  -- drop items whose buffer was wiped (e.g. closed mid-check) to avoid E92
  local items = {}
  for _, it in ipairs(st.items) do
    if it.bufnr and vim.api.nvim_buf_is_valid(it.bufnr) then items[#items + 1] = it end
  end
  st.items = items
  -- the quickfix is a single shared list; only own it when this review's tab is
  -- active, so a background review's checkers don't hijack the one you're reading.
  if st == reviews[vim.api.nvim_get_current_tabpage()] then
    vim.fn.setqflist({}, "r", { title = "Review checkers", items = items })
  end
  local by_buf = {}
  for _, it in ipairs(items) do
    by_buf[it.bufnr] = by_buf[it.bufnr] or {}
    table.insert(by_buf[it.bufnr], {
      lnum = it.lnum - 1, col = 0, message = it.text,
      severity = vim.diagnostic.severity.WARN, source = "ReviewView",
    })
  end
  -- reset diagnostics for THIS review's buffers only (never other tabs'), re-set
  for _, b in pairs(st.file_bufs or {}) do
    if vim.api.nvim_buf_is_valid(b) then vim.diagnostic.reset(NS, b) end
  end
  for buf, diags in pairs(by_buf) do
    if vim.api.nvim_buf_is_valid(buf) then vim.diagnostic.set(NS, buf, diags) end
  end
end

-- Quickfix navigation that stays INSIDE the review diff window (never splits).
local function qf_show(idx)
  sync()
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
  local p = M.file_for(it.bufnr)
  if p then paint_dels(S, p) end   -- realign deleted lines for the gutter this buffer shows with
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
  if #pdiff > MAX_DIFF_CHARS then
    -- Cut back to the last COMPLETE line so we never split a token mid-line
    -- (a mid-token cut made the AI report false "incomplete code" syntax errors).
    local cut = pdiff:sub(1, MAX_DIFF_CHARS)
    cut = cut:sub(1, (cut:match(".*()\n") or (#cut + 1)) - 1)
    pdiff = cut .. "\n[... diff truncated for length. Do NOT report syntax errors, "
      .. "unbalanced/unclosed brackets, or 'incomplete code' caused by this cut-off. ...]"
  end
  local subjects = rc.format_subjects(rc.commit_subjects(st.root, (st.view_left or st.merge_base),
    st.view_ref or "HEAD", 10))
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
          if not is_live(st) then return end   -- review closed: drop late output
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
            if not is_live(st) then return end   -- review closed: drop late results
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

-- Run the checkers on the file currently shown in the diff pane (the `r` key
-- there mirrors `r` in the sidebar).
function M.run_checkers_current()
  sync()
  if not S or not S.current_file then
    vim.notify("review_view: no file shown to check", vim.log.levels.WARN)
    return
  end
  run_checkers(S, S.current_file, { force = true })
end

-- Push the current branch to the remote; force uses --force-with-lease (safe
-- force). On a non-fast-forward rejection of a normal push, offers to force.
local function push_branch(root, remote, branch, force)
  local args = { "git", "-C", root, "push" }
  if force then args[#args + 1] = "--force-with-lease" end
  vim.list_extend(args, { "-u", remote, branch })
  vim.notify(("review_view: %spushing %s to %s..."):format(force and "force-" or "", branch, remote),
    vim.log.levels.INFO)
  vim.system(args, { text = true }, function(res)
    vim.schedule(function()
      if res.code == 0 then
        vim.notify(("review_view: %spushed %s → %s"):format(force and "force-" or "", branch, remote),
          vim.log.levels.INFO)
        return
      end
      local err = vim.trim((res.stderr or "") .. (res.stdout or ""))
      local rejected = err:match("non%-fast%-forward") or err:match("%[rejected%]")
        or err:match("fetch first") or err:match("force")
      if not force and rejected then
        if vim.fn.confirm("Push rejected — remote has diverged.\nForce-push (with lease)?",
          "&No\n&Yes", 1) == 2 then
          push_branch(root, remote, branch, true)
          return
        end
      end
      vim.notify("review_view: push failed:\n" .. err, vim.log.levels.ERROR)
    end)
  end)
end

-- Push the current branch to the remote (P). Refuses on a detached HEAD (e.g. a
-- ReviewMR worktree review — there's no branch to push). Confirms first, with a
-- Force-push option.
function M.push()
  if not sync() then return end
  local root = S.root
  local ok, br = git(root, { "symbolic-ref", "--quiet", "--short", "HEAD" })
  local branch = ok and br[1] or nil
  if not branch or branch == "" then
    vim.notify("review_view: HEAD is detached (MR review?) — nothing to push", vim.log.levels.WARN)
    return
  end
  local remote = remote_name()
  local choice = vim.fn.confirm(("Push '%s' to %s?"):format(branch, remote),
    "&Push\n&Force-push\n&Cancel", 1)
  if choice == 1 then
    push_branch(root, remote, branch, false)
  elseif choice == 2 then
    push_branch(root, remote, branch, true)
  end
end

-- Rebase the current branch onto the latest base (B): fetch <remote>/develop,
-- then `git rebase <remote>/develop`. On conflicts, offers to abort. Refuses on
-- a detached HEAD (ReviewMR worktree). Refreshes the review afterward.
function M.rebase()
  if not sync() then return end
  local root = S.root
  local ok, br = git(root, { "symbolic-ref", "--quiet", "--short", "HEAD" })
  local branch = ok and br[1] or nil
  if not branch or branch == "" then
    vim.notify("review_view: HEAD is detached (MR review?) — cannot rebase", vim.log.levels.WARN)
    return
  end
  local remote = remote_name()
  local base = S.base:gsub("^" .. remote .. "/", "")
  local onto = remote .. "/" .. base
  if vim.fn.confirm(("Rebase '%s' onto latest %s?"):format(branch, onto), "&Yes\n&No", 2) ~= 1 then return end

  vim.notify(("review_view: fetching %s, rebasing %s onto %s..."):format(base, branch, onto), vim.log.levels.INFO)
  git(root, { "fetch", remote, base })
  vim.system({ "git", "-C", root, "rebase", onto }, { text = true }, function(res)
    vim.schedule(function()
      if res.code == 0 then
        vim.notify(("review_view: rebased %s onto %s"):format(branch, onto), vim.log.levels.INFO)
        M.refresh()
        return
      end
      local err = vim.trim((res.stderr or "") .. (res.stdout or ""))
      local conflict = err:match("CONFLICT") or err:match("could not apply") or err:match("Resolve all conflicts")
      if conflict then
        -- Roll back so the working tree is exactly as before; resolve manually.
        git(root, { "rebase", "--abort" })
        vim.notify(("review_view: rebase onto %s has CONFLICTS — rolled back, nothing changed.\n"
          .. "Rebase manually to resolve:  git rebase %s"):format(onto, onto), vim.log.levels.WARN)
      else
        vim.notify("review_view: rebase failed:\n" .. err, vim.log.levels.ERROR)
      end
      M.refresh()
    end)
  end)
end

-- Root of the per-ticket notes tree (…/tasks/<TICKET>/). Configurable so this
-- isn't hard-wired to one checkout; defaults to the nbs-art tasks folder.
local function tasks_root()
  local ok, sl = pcall(require, "config.settings_local")
  local t = ok and type(sl) == "table" and sl.tasks_dir
  return vim.fn.expand(t or "~/sources/nbs-art/tasks")
end

-- Best-effort Jira ticket KEY for this review, no prompting: from the branch
-- name, else the commit subjects. Matches PROJ-123 style keys. nil if none found.
local function ticket_key(st)
  local function find(s) return s and s:match("%f[%u]%u%u+%-%d+") end
  local t = find(st.head_ref)
  if t then return t end
  for _, s in ipairs(require("config.review_context").commit_subjects(st.root, st.merge_base, "HEAD", 30)) do
    t = find(s); if t then return t end
  end
  return nil
end

-- Fetch Jira `key` (async), store it on st.ticket, mirror it into the tasks dir,
-- refresh the sidebar node, then call cb() (if given). Notifies on failure.
local function fetch_ticket(st, key, cb)
  local jira = require("config.jira")
  if not jira.enabled() then
    vim.notify("review_view: Jira integration is off (set jira.enabled = true in settings_local)",
      vim.log.levels.WARN)
    return
  end
  if not jira.configured() then
    vim.notify("review_view: no Jira token configured (settings_local.jira / $JIRA_API_TOKEN)",
      vim.log.levels.WARN)
    return
  end
  jira.fetch(key, function(issue, err)
    if not is_live(st) then return end
    if not issue then
      vim.notify("review_view: Jira " .. key .. " fetch failed" .. (err and (": " .. err) or ""),
        vim.log.levels.WARN)
      return
    end
    local md = jira.render_md(issue)
    st.ticket = { key = key, summary = issue.summary, type = issue.type, status = issue.status, md = md }

    -- mirror into <tasks>/<KEY>/ticket.md, but never clobber a hand-authored one
    local dir = tasks_root() .. "/" .. key
    vim.fn.mkdir(dir, "p")
    local file = dir .. "/ticket.md"
    if vim.fn.filereadable(file) == 1 then
      local first = (vim.fn.readfile(file, "", 1) or {})[1] or ""
      if not first:find("auto-generated from Jira", 1, true) then
        file = dir .. "/ticket-jira.md"   -- side-file; leave the user's ticket.md alone
      end
    end
    vim.fn.writefile(md, file)
    st.ticket.file = file

    if st.sidebar_buf and vim.api.nvim_buf_is_valid(st.sidebar_buf) then
      render_sidebar(st.sidebar_buf, st)
    end
    vim.notify(("review_view: Jira %s — %s  (saved → %s)"):format(
      key, issue.summary, vim.fn.fnamemodify(file, ":~")), vim.log.levels.INFO)
    if cb then cb() end
  end)
end

-- Auto-load on open/refresh: only when a key can be inferred (never prompts).
local function load_ticket(st)
  local jira = require("config.jira")
  if not (jira.enabled() and jira.configured()) then return end   -- trigger off → no-op
  local key = ticket_key(st)
  if not key then return end
  if st.ticket and st.ticket.key == key then return end
  fetch_ticket(st, key)
end

-- Show the fetched Jira ticket in the main (diff) window. `focus` moves the cursor
-- into it (used by gJ); the sidebar-node ⏎ path leaves focus in the sidebar.
function M.show_ticket(focus)
  local st = sync()
  if not st or not st.ticket then return end
  if not (st.ticket_buf and vim.api.nvim_buf_is_valid(st.ticket_buf)) then
    st.ticket_buf = new_scratch("markdown")
    pcall(vim.api.nvim_buf_set_name, st.ticket_buf,
      unique_bufname("review://" .. st.repo .. "/" .. st.ticket.key))
  end
  vim.bo[st.ticket_buf].modifiable = true
  vim.api.nvim_buf_set_lines(st.ticket_buf, 0, -1, false, st.ticket.md)
  vim.bo[st.ticket_buf].modifiable = false
  if vim.api.nvim_win_is_valid(st.diff_win) then
    vim.api.nvim_win_set_buf(st.diff_win, st.ticket_buf)
    pcall(vim.api.nvim_win_set_cursor, st.diff_win, { 1, 0 })
    if focus then pcall(vim.api.nvim_set_current_win, st.diff_win) end
  end
end

-- gJ: open the Jira ticket in the main window. Uses the already-loaded ticket,
-- else infers the key from the branch/commits, else asks (peer MRs where the key
-- isn't in the commits — type e.g. the NBSART-N from the MR title). Fetches on
-- demand, mirrors to tasks, and focuses the pane so you can read it immediately.
function M.open_ticket()
  local st = sync()
  if not st then return end
  if not require("config.jira").enabled() then
    vim.notify("review_view: Jira integration is off (set jira.enabled = true in settings_local)",
      vim.log.levels.WARN)
    return
  end
  local key = (st.ticket and st.ticket.key) or ticket_key(st)
  if not key then
    key = vim.trim(vim.fn.input("Jira ticket to open (e.g. NBSART-660): "))
    if key == "" then return end
  end
  if st.ticket and st.ticket.key == key and st.ticket.md then
    M.show_ticket(true); return
  end
  fetch_ticket(st, key, function() M.show_ticket(true) end)
end

-- Close the review in the CURRENT tab (each tab holds its own review).
-- Returns true if one was open and got closed, false otherwise.
function M.close()
  local st = sync()
  if not st then return false end
  local on_close = st.on_close
  -- wipe the per-file scratch buffers + placeholder + sidebar (clears their
  -- diagnostics too); reset any stragglers, scoped so other tabs are untouched.
  local bufs = vim.tbl_values(st.file_bufs or {})
  if st.placeholder_buf then table.insert(bufs, st.placeholder_buf) end
  if st.sidebar_buf then table.insert(bufs, st.sidebar_buf) end
  for _, b in ipairs(bufs) do
    if b and vim.api.nvim_buf_is_valid(b) then
      pcall(vim.diagnostic.reset, NS, b)
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  if st.tabpage then reviews[st.tabpage] = nil end
  if st.tabpage and vim.api.nvim_tabpage_is_valid(st.tabpage) and #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, "tabclose")
  end
  S = nil
  if on_close then pcall(on_close) end
  return true
end

-- Recompute the file list + diffs against the CURRENT working tree (e.g. after a
-- git checkout / new commit), wiping cached buffers and findings. Keeps the view.
function M.refresh()
  local st = sync()
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
  local okp, pref = git(st.root, { "rev-parse", "--verify", "--quiet", "@{u}" })
  st.pushed_ref = (okp and pref[1] and pref[1] ~= "") and pref[1] or nil

  -- detach the diff pane before wiping its buffers
  if vim.api.nvim_win_is_valid(st.diff_win) and st.placeholder_buf then
    vim.api.nvim_win_set_buf(st.diff_win, st.placeholder_buf)
  end
  for _, b in pairs(st.file_bufs) do
    if vim.api.nvim_buf_is_valid(b) then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
  end
  st.file_bufs, st.diffs, st.linemaps, st.dels = {}, {}, {}, {}
  st.items, st.done, st.inflight = {}, {}, {}
  st.current_file = nil
  -- deleting the file buffers above already cleared their diagnostics; only clear
  -- the shared quickfix (this review owns the active tab during a user refresh).
  vim.fn.setqflist({}, "r", { title = "Review checkers", items = {} })

  -- (re)list the branch's commits; if the commit we're viewing has vanished (rebase,
  -- amend, reset), fall back to the live view rather than diffing against a dead sha.
  st.commits = list_commits(st.root, st.merge_base, "HEAD", 200)
  if st.view_ref then
    local alive = false
    for _, c in ipairs(st.commits) do if c.sha == st.view_ref then alive = true break end end
    if not alive then
      st.view_ref, st.view_left, st.view_short, st.view_single = nil, nil, nil, nil
      vim.notify("review_view: the viewed commit is gone (rebase/amend?) — back to live", vim.log.levels.WARN)
    end
  end

  if st.view_ref then
    st.files = collect_files_at(st.root, (st.view_left or st.merge_base), st.view_ref)
  else
    st.files = collect_files(st.root, st.base, st.merge_base, st.head_ref, st.pushed_ref)
  end
  st.upstream = upstream_status(st.root)
  ensure_tags(st, true) -- code may have moved since last index
  render_sidebar(st.sidebar_buf, st)
  load_ticket(st)       -- (re)fetch the Jira ticket if not already loaded

  -- Keep the same file on screen after the rebuild. Prefer its entry from the new
  -- file list (so diff overlays/checkers stay wired up); otherwise — e.g. switching
  -- to a commit that didn't touch this file — synthesize a bare entry so we still
  -- show the file as it stood at that commit (or "no file in the commit" if absent).
  if prev_path then
    local entry
    for _, e in ipairs(st.files) do
      if e.path == prev_path then entry = e; break end
    end
    entry = entry or { path = prev_path }
    show_file(st, entry)
    if prev_view and vim.api.nvim_win_is_valid(st.diff_win) then
      local lines = vim.api.nvim_buf_line_count(st.file_bufs[prev_path] or -1)
      prev_view.lnum = math.min(prev_view.lnum, math.max(1, lines))
      vim.api.nvim_win_call(st.diff_win, function() vim.fn.winrestview(prev_view) end)
    end
  end
  vim.notify(("review_view: refreshed (%d files)"):format(#st.files), vim.log.levels.INFO)
end

-- Browse a commit as a checkpoint. Default (opts.single false): show the branch as
-- it stood at `sha` — the whole feature diffed base…sha, "as if sha were HEAD".
-- opts.single: show only what `sha` itself changed (its parent…sha). Rebuilds the
-- file list + overlays for that snapshot; the working tree is never touched.
function M.view_commit(sha, opts)
  local st = sync()
  if not st then return end
  opts = opts or {}
  st.view_ref = sha
  st.view_single = opts.single or nil
  st.view_left = opts.single and (sha .. "~1") or nil
  st.view_short = sha:sub(1, 8)
  for _, c in ipairs(st.commits or {}) do if c.sha == sha then st.view_short = c.short; break end end
  M.refresh()
  vim.notify(("review_view: viewing @%s (%s)"):format(
    st.view_short, opts.single and "this commit only" or "as if it were HEAD"), vim.log.levels.INFO)
end

-- Return to the live view: HEAD plus uncommitted edits and untracked files.
function M.view_live()
  local st = sync()
  if not st then return end
  if not st.view_ref then return end
  st.view_ref, st.view_left, st.view_short, st.view_single = nil, nil, nil, nil
  M.refresh()
  vim.notify("review_view: back to live (working tree)", vim.log.levels.INFO)
end

-- The visible file rows in sidebar order, as { row, entry }. Skips folder headers
-- and the ticket/commit/live nodes, and (naturally) files inside collapsed folders.
local function file_rows(st)
  local out, rows = {}, {}
  for row in pairs(st.line_index or {}) do rows[#rows + 1] = row end
  table.sort(rows)
  for _, row in ipairs(rows) do
    local e = st.line_index[row]
    if e and e.path and not (e.ticket or e.commit or e.live) then
      out[#out + 1] = { row = row, entry = e }
    end
  end
  return out
end

-- J/K: step to the next/prev file in the tree (dir = +1 / -1) and show its diff,
-- keeping the sidebar cursor in sync. Clamps at the ends (no wrap).
function M.step_file(dir)
  local st = sync()
  if not st then return end
  local files = file_rows(st)
  if #files == 0 then return end
  local cur = st.current_file and st.current_file.path
  local idx
  for i, f in ipairs(files) do if f.entry.path == cur then idx = i; break end end
  local nxt = idx and (idx + dir) or (dir > 0 and 1 or #files)
  if nxt < 1 or nxt > #files then return end
  local f = files[nxt]
  show_file(st, f.entry)
  if vim.api.nvim_win_is_valid(st.sidebar_win) then
    pcall(vim.api.nvim_win_set_cursor, st.sidebar_win, { f.row, 0 })
  end
end

-- U/D: step through the checkpoint list (index 1 = working-tree/live, then the
-- commits newest→oldest). dir = -1 moves up toward live, +1 down toward older.
-- The currently-open file follows the switch (see M.refresh). Clamps at the ends.
function M.step_commit(dir)
  local st = sync()
  if not st then return end
  local targets = { { live = true } }
  for _, c in ipairs(st.commits or {}) do targets[#targets + 1] = { commit = c.sha } end
  if #targets <= 1 then return end
  local idx = 1
  if st.view_ref then
    for i = 2, #targets do if targets[i].commit == st.view_ref then idx = i; break end end
  end
  local nxt = idx + dir
  if nxt < 1 or nxt > #targets then return end
  local t = targets[nxt]
  if t.live then M.view_live() else M.view_commit(t.commit) end
  -- park the sidebar cursor on the now-active commit/live row (line_index is fresh
  -- after the refresh that view_live/view_commit triggered)
  if vim.api.nvim_win_is_valid(st.sidebar_win) then
    for row, e in pairs(st.line_index or {}) do
      if (t.live and e.live) or (e.commit and e.commit == t.commit) then
        pcall(vim.api.nvim_win_set_cursor, st.sidebar_win, { row, 0 }); break
      end
    end
  end
end

local function entry_under_cursor()
  if not sync() then return nil end
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
  -- Pin the sign column to a fixed width: checker findings add diagnostic signs
  -- later, and with the default "auto" the gutter would widen after the deleted
  -- lines are painted, knocking them out of alignment (paint_dels pads to textoff).
  vim.wo[st.diff_win].signcolumn = "yes:1"
  st.placeholder_buf = new_scratch(nil)
  -- Build the COLOUR legend with real on-screen swatches: a swatch is a run of
  -- spaces highlighted with the actual line-background group, so the reader sees
  -- the colour rather than just its name. (Block glyphs wouldn't work — a bg-only
  -- highlight is hidden behind a filled glyph.) Returns the line text plus the byte
  -- columns of each swatch so we can extmark them after the buffer is populated.
  local vivid_hls = { "ReviewViewAddLineNew", "ReviewViewChangeLineNew", "ReviewViewDelLineNew" }
  local dim_hls   = { "ReviewViewAddLine", "ReviewViewChangeLine", "ReviewViewDelLine" }
  local function swatch_line(hls)
    local labels = { "added", "changed", "removed" }
    local text, marks = "    ", {}
    for i = 1, 3 do
      local col = #text
      text = text .. "    "                       -- 4-space swatch
      marks[#marks + 1] = { col = col, endc = #text, hl = hls[i] }
      text = text .. " " .. labels[i] .. "    "
    end
    return text, marks
  end
  local vivid_text, vivid_marks = swatch_line(vivid_hls)
  local dim_text, dim_marks = swatch_line(dim_hls)

  vim.api.nvim_buf_set_lines(st.placeholder_buf, 0, -1, false, {
    "",
    "  REVIEW — red/green patch view      (press ? to show this help)",
    "",
    "  COLOURS   diff-pane line background:",
    vivid_text .. "  vivid = unpushed (new since last push)",
    dim_text .. "  dim = already pushed",
    "  sidebar marks:  ↑ unpushed   ● uncommitted   + new   (blank = pushed)",
    "",
    "  COMMITS   browse each commit as a checkpoint (in the Commits section)",
    "    ⏎ on a commit  view it as if it were HEAD    s  view that commit only",
    "    ⏎ on 'working tree (live)' or gh anywhere    back to the live view",
    "    U / D   step commits up (→ live) / down (→ older), file follows",
    "",
    "  SIDEBAR (file list)",
    "    ⏎      show diff / fold / ticket     r        run checkers",
    "    J / K   next / prev file             U / D    step commits (→live / →older)",
    "    gJ      open Jira ticket (asks for key if unknown) → main window + tasks/",
    "    Tab/za  fold folder                  zM/zR    fold / unfold all",
    "    X       revert WHOLE file → base     C        CodeCompanion chat",
    "    P       push (Force option)          B        rebase onto latest base",
    "    R       refresh                      ]q/[q    prev / next finding",
    "    q       close review",
    "",
    "  DIFF PANE",
    "    e       edit file in a tab           C        CodeCompanion (n/v)",
    "    J / K   next / prev file             U / D    step commits (→live / →older)",
    "    <C-]>   go to definition (gd/]d)     <C-t>    jump back  ·  r  run checkers",
    "    B       rebase onto latest base      P        push (Force option)",
    "    X       revert change under cursor → base (develop)",
    "    ]q/[q   prev / next finding          R        refresh",
    "    gJ      open Jira ticket → main window",
    "    q       close review",
    "",
    "  EDIT TAB (after pressing e)",
    "    gR      save & back to review        gt/gT    switch tab",
  })
  -- Paint the colour legend: swatches on the vivid/dim rows, and the sidebar mark
  -- glyphs in their own colours. Named groups → these track ColorScheme changes.
  local ph_lines = vim.api.nvim_buf_get_lines(st.placeholder_buf, 0, -1, false)
  local function color_first(row0, line, token, hl)
    local s, e = line:find(token, 1, true)
    if s then vim.api.nvim_buf_set_extmark(st.placeholder_buf, HL_NS, row0, s - 1, { end_col = e, hl_group = hl }) end
  end
  for row0 = 0, #ph_lines - 1 do
    local l = ph_lines[row0 + 1]
    local marks = (l:find("vivid = unpushed", 1, true) and vivid_marks)
      or (l:find("dim = already pushed", 1, true) and dim_marks)
    if marks then
      for _, m in ipairs(marks) do
        vim.api.nvim_buf_set_extmark(st.placeholder_buf, HL_NS, row0, m.col, { end_col = m.endc, hl_group = m.hl })
      end
    elseif l:find("sidebar marks:", 1, true) then
      color_first(row0, l, "↑", "ReviewViewNew")
      color_first(row0, l, "●", "ReviewViewDirty")
      color_first(row0, l, "+", "ReviewViewAdd")
    end
  end
  vim.bo[st.placeholder_buf].modifiable = false
  vim.api.nvim_win_set_buf(st.diff_win, st.placeholder_buf)
  setup_diff_keymaps(st.placeholder_buf)

  -- left vertical split for the sidebar
  vim.cmd("topleft vsplit")
  st.sidebar_win = vim.api.nvim_get_current_win()
  st.sidebar_buf = new_scratch("ReviewView")
  -- Name the sidebar buffer after the repo so the tab label reads as the repo
  -- (focus stays here while browsing) instead of a generic "[Scratch]".
  pcall(vim.api.nvim_buf_set_name, st.sidebar_buf, unique_bufname("review://" .. st.repo))
  vim.api.nvim_win_set_buf(st.sidebar_win, st.sidebar_buf)
  vim.api.nvim_win_set_width(st.sidebar_win, SIDEBAR_WIDTH)
  vim.wo[st.sidebar_win].number = false
  vim.wo[st.sidebar_win].relativenumber = false
  vim.wo[st.sidebar_win].wrap = false

  local o = { buffer = st.sidebar_buf, nowait = true, silent = true }
  vim.keymap.set("n", "<CR>", function()
    -- Ticket node → show the Jira ticket. Commit node → view that checkpoint. Live
    -- node → back to the working tree. Folder header → fold/unfold. File → show diff.
    local e = entry_under_cursor()
    if e and e.ticket then M.show_ticket(); return end
    if e and e.live then M.view_live(); return end
    if e and e.commit then M.view_commit(e.commit); return end
    if toggle_fold(st) then return end
    if e then show_file(st, e) end
  end, o)
  -- `s` on a commit node: view ONLY that commit's own change (its parent…commit).
  vim.keymap.set("n", "s", function()
    local e = entry_under_cursor()
    if e and e.commit then M.view_commit(e.commit, { single = true }) end
  end, o)
  vim.keymap.set("n", "gh", function() M.view_live() end, o)
  vim.keymap.set("n", "r", function()
    local e = entry_under_cursor()
    if e and not e.ticket and not e.commit and not e.live then run_checkers(st, e, { force = true }) end
  end, o)
  vim.keymap.set("n", "<Tab>", function() toggle_fold(st) end, o)
  vim.keymap.set("n", "za", function() toggle_fold(st) end, o)
  vim.keymap.set("n", "zM", function() fold_all(st, true) end, o)
  vim.keymap.set("n", "zR", function() fold_all(st, false) end, o)
  vim.keymap.set("n", "R", function() M.refresh() end, o)
  vim.keymap.set("n", "P", function() M.push() end, o)
  vim.keymap.set("n", "B", function() M.rebase() end, o)
  vim.keymap.set("n", "gJ", function() M.open_ticket() end, o)
  vim.keymap.set("n", "X", function() M.revert_file_under_cursor() end, o)
  vim.keymap.set("n", "J", function() M.step_file(1) end, o)
  vim.keymap.set("n", "K", function() M.step_file(-1) end, o)
  vim.keymap.set("n", "U", function() M.step_commit(-1) end, o)
  vim.keymap.set("n", "D", function() M.step_commit(1) end, o)
  vim.keymap.set("n", "C", function() M.codecompanion({ entry = entry_under_cursor() }) end, o)
  vim.keymap.set("n", "?", function() M.show_help() end, o)
  vim.keymap.set("n", "q", M.close, o)
  vim.keymap.set("n", "]q", function() M.qf_next() end, o)
  vim.keymap.set("n", "[q", function() M.qf_prev() end, o)
end

-- Bring the base branch up to its origin state so the review is against the
-- latest develop. Best-effort: refresh origin/<base>, then fast-forward the local
-- branch ref (git skips it automatically if <base> is checked out or not a ff).
local function refresh_base(root, base)
  local remote = remote_name()
  local branch = base:gsub("^" .. remote .. "/", "")
  git(root, { "fetch", remote, branch })
  git(root, { "fetch", remote, branch .. ":" .. branch })
end

-- Open the review view for the repo containing `path` (file or directory).
-- opts.head_label overrides the displayed HEAD name (e.g. a detached MR review);
-- opts.on_close is called when the view is closed (e.g. to remove a worktree).
function M.open(path, opts)
  opts = opts or {}
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

  -- Pull the base branch (develop) up to origin before diffing.
  refresh_base(root, base)

  local okb, branch = git(root, { "symbolic-ref", "--short", "HEAD" })
  local head_ref = opts.head_label
    or ((okb and branch[1] and branch[1] ~= "") and branch[1] or "HEAD")

  local okm, mb = git(root, { "merge-base", base, "HEAD" })
  local merge_base = (okm and mb[1] and mb[1] ~= "") and mb[1] or base

  -- Remote feature branch (@{u}) sha, or nil on a detached HEAD / no upstream —
  -- the reference for the pushed-vs-unpushed colouring.
  local okp, pref = git(root, { "rev-parse", "--verify", "--quiet", "@{u}" })
  local pushed_ref = (okp and pref[1] and pref[1] ~= "") and pref[1] or nil

  local files = collect_files(root, base, merge_base, head_ref, pushed_ref)
  if #files == 0 then
    vim.notify(("review_view: no changes in %s...%s"):format(base, head_ref), vim.log.levels.INFO)
    return
  end

  -- Each call opens an independent review in its own tab; existing reviews stay.
  S = {
    root = root, base = base, head_ref = head_ref, merge_base = merge_base,
    pushed_ref = pushed_ref,   -- @{u} sha: reference for pushed-vs-unpushed colours
    repo = repo_name(root), tags_file = tags_path(root),
    mr_iid = opts.mr_iid,   -- set by :ReviewMR; the GitLab MR number this review came from
    on_close = opts.on_close,
    files = files, collapsed = {},
    commits = list_commits(root, merge_base, "HEAD", 200),  -- checkpoints to browse
    view_ref = nil, view_left = nil, view_short = nil, view_single = nil,  -- live by default
    file_bufs = {}, diffs = {}, linemaps = {}, dels = {},  -- per-file caches
    items = {},                                 -- accumulated quickfix items (tagged _file/_checker)
    inflight = {}, done = {},                    -- path -> running count / completed
  }
  S.upstream = upstream_status(root)
  ensure_tags(S, true) -- (re)index the repo so <C-]> resolves definitions
  build_ui(S)                    -- creates the tab; sets S.tabpage
  reviews[S.tabpage] = S         -- register this review under its tab
  -- start fresh: this review owns the shared quickfix while its tab is active
  vim.fn.setqflist({}, "r", { title = "Review checkers", items = {} })
  render_sidebar(S.sidebar_buf, S)
  load_ticket(S)        -- fetch the Jira ticket (async) → sidebar node + tasks mirror
  -- No file is shown on open (empty placeholder) so nothing runs until selection.
  if vim.api.nvim_win_is_valid(S.sidebar_win) then
    vim.api.nvim_set_current_win(S.sidebar_win)
    pcall(vim.api.nvim_win_set_cursor, S.sidebar_win, { 6, 0 })
  end
  vim.notify(("review_view: %s   %s → %s   (%d files)"):format(S.repo, base, head_ref, #files),
    vim.log.levels.INFO)
end

-- Repo-relative path of the file whose diff buffer is `bufnr`, or nil.
function M.file_for(bufnr)
  local r = review_for_buf(bufnr)
  if not r then return nil end
  for path, b in pairs(r.file_bufs or {}) do
    if b == bufnr then return path end
  end
  return nil
end

-- Short tag for the version being viewed in a diff buffer: "live" (working tree)
-- or "@<sha>" / "commit @<sha>" (a checkpoint). Empty for non-diff buffers so a
-- statusline component (see lualine config) can show it beside the file path.
function M.view_tag_for(bufnr)
  local st = review_for_buf(bufnr or vim.api.nvim_get_current_buf())
  if not st then return "" end
  if st.view_ref then
    return (st.view_single and "commit @" or "@") .. (st.view_short or st.view_ref:sub(1, 8))
  end
  return "live"
end

-- The real on-disk path of the file shown in diff buffer `bufnr`, or nil if
-- `bufnr` is not one of our diff panes. Diff buffers are `nofile` and named with
-- a virtual `review://` scheme, so external tools (e.g. the markdown preview)
-- need this to resolve them back to the actual file on disk.
function M.real_path_for(bufnr)
  local st = review_for_buf(bufnr)
  local path = M.file_for(bufnr)
  if not (st and path) then return nil end
  return st.root .. "/" .. path
end

-- Describe a diff-buffer row range for external consumers (e.g. kitty_drop):
-- maps the selected rows back to SOURCE line numbers via the file's line map.
-- Returns { file = relpath, l1 = srcStart, l2 = srcEnd, lines = {selected diff lines} }
-- or nil if `bufnr` is not one of our diff buffers.
function M.context_for(bufnr, r1, r2)
  local st = review_for_buf(bufnr)
  local path = M.file_for(bufnr)
  if not (st and path) then return nil end
  if r1 > r2 then r1, r2 = r2, r1 end
  local linemap = (st.linemaps or {})[path] or {}
  local lo, hi
  for src, row in pairs(linemap) do
    if row >= r1 and row <= r2 then
      lo = (not lo or src < lo) and src or lo
      hi = (not hi or src > hi) and src or hi
    end
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, r1 - 1, r2, false)
  return {
    file = path, l1 = lo, l2 = hi, lines = lines, ft = vim.bo[bufnr].filetype,
    repo = st.repo, base = st.base, head = st.head_ref,   -- which repo / branches
  }
end

-- After a working-tree revert of committed changes, the file no longer matches
-- HEAD — committed work has been undone as an unstaged edit. Say so loudly, since
-- that dirty state blocks a rebase/switch until it's committed or stashed.
local function warn_if_dirty_vs_head(root, path)
  local out = vim.fn.systemlist({ "git", "-C", root, "diff", "--name-only", "HEAD", "--", path })
  if vim.v.shell_error == 0 and out[1] and out[1] ~= "" then
    vim.notify(("review_view: %s now differs from HEAD — committed work was undone in the working tree.\n"
      .. "Commit or stash before rebasing/switching (git rebase refuses a dirty tree)."):format(path),
      vim.log.levels.WARN)
  else
    vim.notify("review_view: reverted file " .. path, vim.log.levels.INFO)
  end
end

-- Revert the change under the cursor back to its base (develop) state: replace
-- the hunk's new lines with the base version (delete added lines / restore
-- deleted lines / swap changed lines), write the file, then refresh the overlay.
-- Modifies the working tree, so it asks for confirmation first.
function M.revert_under_cursor()
  local st = sync()
  if not st then return end
  if st.view_ref then
    vim.notify("review_view: revert unavailable while viewing a commit — press gh for live", vim.log.levels.WARN)
    return
  end
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
  local hunks = parse_hunks(st.root, st.merge_base, nil, path)
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
  local warn = (entry and entry.committed)
    and "\n  ⚠ this file has committed changes — the revert lands as an unstaged edit\n"
      .. "    (commit stays; tree goes dirty, blocks rebase/switch until committed/stashed)"
    or ""
  if vim.fn.confirm(("Revert this change to %s?\n  %s%s"):format(st.base or "base", what, warn),
    "&Yes\n&No", 2) ~= 1 then
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
  if entry and entry.committed then
    warn_if_dirty_vs_head(st.root, path)
  else
    vim.notify("review_view: reverted change in " .. path, vim.log.levels.INFO)
  end
end

-- Revert the WHOLE file under the cursor (in the sidebar) back to its base
-- (develop) state: restore the base content, or delete it if the file is new in
-- this branch. Confirms first since it discards every change in that file.
function M.revert_file_under_cursor()
  if not sync() then return end
  local st = S
  if st.view_ref then
    vim.notify("review_view: revert unavailable while viewing a commit — press gh for live", vim.log.levels.WARN)
    return
  end
  local e = entry_under_cursor()
  if not e or e.ticket or e.commit or e.live then
    vim.notify("review_view: put the cursor on a file in the sidebar", vim.log.levels.WARN)
    return
  end
  local path = e.path
  local abspath = st.root .. "/" .. path

  vim.fn.systemlist({ "git", "-C", st.root, "cat-file", "-e", st.merge_base .. ":" .. path })
  local in_base = vim.v.shell_error == 0

  if not in_base then
    -- New file in this branch (base had none): delete it.
    if vim.fn.confirm(("Revert whole file to %s?\n  delete new file %s"):format(st.base or "base", path),
      "&Yes\n&No", 2) ~= 1 then return end
    vim.fn.delete(abspath)
    vim.cmd("checktime"); M.refresh()
    vim.notify("review_view: deleted new file " .. path, vim.log.levels.INFO)
    return
  end

  if not e.committed then
    -- Uncommitted edits only: HEAD already holds the base version of this file, so
    -- restoring HEAD gives base content AND leaves a CLEAN tree (no dirty residue,
    -- nothing to stash before a rebase).
    if vim.fn.confirm(("Discard uncommitted edits in %s?\n  restore to %s (clean)"):format(path, st.base or "base"),
      "&Yes\n&No", 2) ~= 1 then return end
    vim.fn.systemlist({ "git", "-C", st.root, "checkout", "HEAD", "--", path })
    vim.cmd("checktime"); M.refresh()
    vim.notify("review_view: reverted file " .. path .. " (clean)", vim.log.levels.INFO)
    return
  end

  -- Committed changes: writing base content only touches the WORKING TREE — the
  -- commits stay, so the tree goes dirty (which blocks rebase/switch until committed
  -- or stashed). Spell that out before and after.
  if vim.fn.confirm(("Revert whole file to %s?\n  ⚠ committed change(s) will be undone in the WORKING TREE only —\n"
    .. "  commits stay; tree becomes dirty (blocks rebase/switch until committed/stashed)."):format(st.base or "base"),
    "&Yes\n&No", 2) ~= 1 then return end
  if e.binary then
    vim.fn.systemlist({ "git", "-C", st.root, "checkout", st.merge_base, "--", path })
  else
    local content = vim.fn.systemlist({ "git", "-C", st.root, "show", st.merge_base .. ":" .. path })
    vim.fn.writefile(content, abspath)
  end
  vim.cmd("checktime")
  M.refresh()
  warn_if_dirty_vs_head(st.root, path)
end

-- Open the real file shown in the current diff pane in a (reused) edit tab, at
-- the source line under the cursor. `gR` in that buffer saves and returns to the
-- review (refreshing the diff to reflect the edits).
function M.edit_under_cursor()
  local st = sync()
  if not st then return end
  if st.view_ref then
    vim.notify("review_view: editing shows the on-disk file, which differs from this commit — press gh for live",
      vim.log.levels.WARN)
    return
  end
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

  vim.keymap.set("n", "gR", function() M.edit_return(path, st) end, {
    buffer = vim.api.nvim_get_current_buf(), nowait = true, silent = true,
    desc = "Review: save & back to review",
  })
  vim.notify("review_view: editing " .. path .. "   (gR = save & back, gt = review tab)",
    vim.log.levels.INFO)
end

-- Save the edit buffer (if a real, modified file), close the edit tab, return to
-- the review tab, refresh the diffs and re-show the edited file's diff.
-- `review` is captured from edit_under_cursor: this fires in the EDIT tab, so we
-- can't resolve the review from the current tabpage — sync() would return nil.
function M.edit_return(path, review)
  if vim.bo.buftype == "" and vim.bo.modifiable and not vim.bo.readonly and vim.bo.modified then
    pcall(vim.cmd, "write")
  end
  local st = review or sync()
  if not st then return end
  local review_tab = st.tabpage
  if st.edit_tab and vim.api.nvim_tabpage_is_valid(st.edit_tab)
      and #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, "tabclose")
    st.edit_tab = nil
  end
  if review_tab and vim.api.nvim_tabpage_is_valid(review_tab) then
    pcall(vim.api.nvim_set_current_tabpage, review_tab)
  end
  sync()          -- now on the review tab; make it the active review
  M.refresh()
  -- re-display the file we just edited, if it still has changes
  if path then
    for _, e in ipairs(st.files or {}) do
      if e.path == path then show_file(st, e); break end
    end
  end
end

-- Open a CodeCompanion chat seeded with the current review context: the file
-- under review, its diff, the checker findings, and commit subjects. opts.entry
-- overrides the file (e.g. the sidebar row under the cursor); opts.visual adds the
-- current visual selection as a focus block.
function M.codecompanion(opts)
  opts = opts or {}
  local st = sync()
  if not st then return end
  local cc_ok, cc = pcall(require, "codecompanion")
  if not cc_ok then
    vim.notify("review_view: CodeCompanion not available", vim.log.levels.WARN); return
  end
  local entry = opts.entry or st.current_file
  if entry and (entry.ticket or entry.commit or entry.live) then
    entry = st.current_file   -- ticket / commit / live nodes aren't files
  end
  if not entry then
    vim.notify("review_view: select a file first (⏎)", vim.log.levels.WARN); return
  end
  local path = entry.path
  local rc = require("config.review_context")

  -- make sure the file's diff is computed/cached
  if not st.diffs[path] then ensure_file_buf(st, entry) end

  local parts = {}
  local right_desc = st.view_ref and ("commit " .. st.view_short) or "working tree"
  table.insert(parts, ("Reviewing `%s` (`%s` → %s) in repo `%s`."):format(
    path, (st.view_left or st.base), right_desc, rc.repo_name(st.root)))

  local subjects = rc.format_subjects(rc.commit_subjects(st.root, (st.view_left or st.merge_base),
    st.view_ref or "HEAD", 30))
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
