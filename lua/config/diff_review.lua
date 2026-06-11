local M = {}

local MAX_DIFF_CHARS = 7000
local NS = vim.api.nvim_create_namespace("diff_review")

M._pending_diags = {}  -- fname → diag[]  (accumulates across files)
M._review_cache  = {}  -- cache_key → entries[]
M._in_progress   = {}  -- cache_key → true
M._all_entries   = {}  -- merged quickfix entries across all reviewed files

local REVIEW_PROMPT = [[Review this diff for bugs, type errors, logic errors, security issues.
Also check comments: flag any that are inaccurate or misleading about what the code actually does,
contain outdated history or change-log notes that belong in git commit messages instead,
or describe unrelated concerns irrelevant to the surrounding block.
For each issue output exactly ONE line:
LOC: <file_path>:<line_number> <brief description>
After all issues: one-sentence summary. No other text.]]

-- Context-aware diff collection:
--   In diffview → current file's diff (or whole diffview range if no file selected)
--   Outside diffview → whole working tree vs base branch (staged + unstaged)
local function get_review_context()
  local rc = require("config.review_context")

  local dv = rc.diffview()
  if dv then
    local diff, err = rc.diff(dv.root, dv.left_sha, dv.right_sha, dv.file, {
      right_is_local = dv.right_is_local,
    })
    if err then return nil, err end
    if not diff or vim.trim(diff) == "" then
      return nil, ("No diff for %s (%s..%s)"):format(
        dv.file or "repo", dv.left_display, dv.right_display)
    end
    local subjects = rc.commit_subjects(dv.root, dv.left_sha, dv.right_sha, 10)
    return {
      diff     = diff,
      info     = dv,
      file     = dv.file,
      subjects = rc.format_subjects(subjects),
    }, nil
  end

  -- Outside diffview: working tree vs base branch (all uncommitted changes)
  local fb = rc.fallback()
  if not fb then return nil, "Not in a git repo" end

  local diff, err = rc.diff(fb.root, fb.left_sha, nil, nil, { right_is_local = true })
  if err or not diff or vim.trim(diff) == "" then
    diff, err = rc.diff(fb.root, fb.left_sha, fb.right_sha, nil, {})
    if err then return nil, err end
  end
  if not diff or vim.trim(diff) == "" then
    return nil, ("No diff vs %s"):format(fb.left_display)
  end
  local subjects = rc.commit_subjects(fb.root, fb.left_sha, fb.right_sha, 10)
  return {
    diff     = diff,
    info     = { root = fb.root, left_display = fb.left_display, right_display = "working tree" },
    file     = nil,
    subjects = rc.format_subjects(subjects),
  }, nil
end

-- Cache key: sha + file path (or sha + "" for whole-repo reviews)
local function make_cache_key(ctx)
  return (ctx.info.left_sha or ctx.info.left_display or "") .. "|" .. (ctx.file or "")
end

local function parse_loc_line(line, root)
  local file, lnum, msg = line:match("^LOC:%s*([^:]+):(%d+)%s+(.+)")
  if not (file and lnum) then return nil end
  local path = (root and not file:match("^/")) and (root .. "/" .. file) or file
  return { filename = path, lnum = tonumber(lnum), col = 1, text = msg, type = "W" }
end

-- Find all buffers for a filepath: exact match + diffview git-object buffers
local function bufs_for_file(filepath)
  local found = {}
  local seen = {}
  local function add(b)
    if b > 0 and vim.api.nvim_buf_is_valid(b) and not seen[b] then
      seen[b] = true; table.insert(found, b)
    end
  end
  add(vim.fn.bufnr(filepath))
  local suffix = filepath:match("[^/]+/[^/]+$") or filepath:match("[^/]+$")
  if suffix then
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):find(suffix, 1, true) then add(b) end
    end
  end
  return found
end

-- Apply diagnostics accumulating across files.
-- Pass clear_pattern (relative path substring) to wipe old diags for just that file
-- before setting new ones; omit to wipe everything (manual/whole-repo review).
local function apply_diagnostics(entries, clear_pattern)
  if clear_pattern then
    for fname in pairs(M._pending_diags) do
      if fname:find(clear_pattern, 1, true) then
        M._pending_diags[fname] = nil
        for _, b in ipairs(bufs_for_file(fname)) do
          vim.diagnostic.set(NS, b, {})
        end
      end
    end
  else
    M._pending_diags = {}
    vim.diagnostic.reset(NS)
  end
  local by_file = {}
  for _, e in ipairs(entries) do
    by_file[e.filename] = by_file[e.filename] or {}
    table.insert(by_file[e.filename], {
      lnum = e.lnum - 1, col = 0,
      message = e.text,
      severity = vim.diagnostic.severity.WARN,
      source = "DiffReview",
    })
  end
  for fname, diags in pairs(by_file) do
    M._pending_diags[fname] = diags
    for _, b in ipairs(bufs_for_file(fname)) do
      vim.diagnostic.set(NS, b, diags)
    end
  end
end

-- Merge new entries for one file into the global quickfix list.
-- Pass clear_pattern=nil to replace everything (whole-repo).
local function update_quickfix(new_entries, clear_pattern)
  if clear_pattern then
    M._all_entries = vim.tbl_filter(function(e)
      return not e.filename:find(clear_pattern, 1, true)
    end, M._all_entries)
  else
    M._all_entries = {}
  end
  for _, e in ipairs(new_entries) do table.insert(M._all_entries, e) end
  vim.fn.setqflist({}, "r", { title = "DiffReview", items = M._all_entries })
end

-- Apply pending diagnostics when a buffer is read or enters a window
-- (catches diffview git-object buffers opened after the review runs)
vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
  group = vim.api.nvim_create_augroup("DiffReviewDiag", { clear = true }),
  callback = function(ev)
    if not vim.api.nvim_buf_is_valid(ev.buf) then return end
    local name = vim.api.nvim_buf_get_name(ev.buf)
    for fname, diags in pairs(M._pending_diags) do
      local suffix = fname:match("[^/]+/[^/]+$") or fname:match("[^/]+$")
      if name == fname or (suffix and name:find(suffix, 1, true)) then
        vim.diagnostic.set(NS, ev.buf, diags)
        break
      end
    end
  end,
})

-- Forward declaration: defined in the auto-trigger section below,
-- but referenced here so the FileType callback can use it.
local auto_check_current_file

-- Diffview panel keymaps
vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("DiffReviewPanel", { clear = true }),
  pattern = { "DiffviewFiles", "DiffviewFileHistory" },
  callback = function(ev)
    vim.keymap.set("n", "<leader>cr", function()
      require("config.diff_review").review()
    end, { buffer = ev.buf, desc = "DiffReview: review file under cursor" })

    -- <CR> selects the file in diffview then auto-reviews it.
    -- defer_fn gives diffview time to finish its own async update of cur_file.
    vim.keymap.set("n", "<CR>", function()
      pcall(require("diffview.actions").select_entry)
      vim.defer_fn(function()
        if auto_check_current_file then auto_check_current_file() end
      end, 300)
    end, { buffer = ev.buf, desc = "Select file + auto DiffReview" })

    -- R refreshes diffview AND clears the review cache so files get re-reviewed
    vim.keymap.set("n", "R", function()
      require("config.diff_review").reset_cache()
      pcall(require("diffview.actions").refresh_files)
    end, { buffer = ev.buf, desc = "Refresh diffview + clear DiffReview cache" })
  end,
})

-- Auto-trigger: review each file when it is opened in diffview, caching results
local _auto_timer = nil
local _auto_pending_key = nil

local function schedule_auto_review(cache_key)
  _auto_pending_key = cache_key
  if _auto_timer then pcall(function() _auto_timer:stop(); _auto_timer:close() end) end
  _auto_timer = vim.uv.new_timer()
  _auto_timer:start(600, 0, vim.schedule_wrap(function()
    _auto_timer = nil
    if _auto_pending_key ~= cache_key then return end
    _auto_pending_key = nil
    if M._review_cache[cache_key] or M._in_progress[cache_key] then return end
    require("config.diff_review").review({ auto = true })
  end))
end

auto_check_current_file = function()
  local ok, sl = pcall(require, "config.settings_local")
  local dr_cfg = (ok and type(sl) == "table" and sl.diff_review) or {}
  if dr_cfg.auto_review == false then return end

  local rc_ok, rc = pcall(require, "config.review_context")
  if not rc_ok then return end
  local dv = rc.diffview()
  if not dv or not dv.file then return end

  local cache_key = (dv.left_sha or "") .. "|" .. dv.file
  if M._review_cache[cache_key] or M._in_progress[cache_key] then return end
  schedule_auto_review(cache_key)
end

local auto_group = vim.api.nvim_create_augroup("DiffReviewAuto", { clear = true })

-- CursorMoved in the panel covers j/k navigation and <CR> file selection.
-- vim.schedule defers one tick so diffview updates panel.cur_file first.
vim.api.nvim_create_autocmd("CursorMoved", {
  group = auto_group,
  callback = function()
    local ft = vim.bo.filetype
    if ft ~= "DiffviewFiles" and ft ~= "DiffviewFileHistory" then return end
    vim.schedule(auto_check_current_file)
  end,
})

-- BufWinEnter on git-object buffers: fires when diffview shows any file's diff,
-- regardless of which window has focus. Catches <CR>, j/k, and initial open.
vim.api.nvim_create_autocmd("BufWinEnter", {
  group = auto_group,
  callback = function(ev)
    local name = vim.api.nvim_buf_get_name(ev.buf)
    -- Skip diffview internal buffers (null, panels); only match real diff content
    if name:find("panels/", 1, true) or name == "diffview://null" then return end
    if not (name:find("%.git/") or name:find("diffview://", 1, true)) then return end
    vim.schedule(auto_check_current_file)
  end,
})

-- WinEnter: fallback for when the user manually focuses a diff window.
vim.api.nvim_create_autocmd("WinEnter", {
  group = auto_group,
  callback = function()
    local ft = vim.bo.filetype
    if ft == "DiffviewFiles" or ft == "DiffviewFileHistory" or ft == "" then return end
    local lib_ok, lib = pcall(require, "diffview.lib")
    if not lib_ok or not lib.get_current_view() then return end
    auto_check_current_file()
  end,
})

-- Clear all results, cache, and diagnostics
function M.clear()
  M._pending_diags = {}
  M._review_cache  = {}
  M._in_progress   = {}
  M._all_entries   = {}
  vim.diagnostic.reset(NS)
  vim.fn.setqflist({}, "r", { title = "DiffReview", items = {} })
  vim.notify("DiffReview: cleared", vim.log.levels.INFO)
end

-- Clear cache only (keeps diagnostics/quickfix visible, re-enables auto-review)
function M.reset_cache()
  M._review_cache = {}
  M._in_progress  = {}
end

-- opts.auto = true  → respect cache and in-progress guard (used by auto-trigger)
-- opts.auto = false/nil → manual: always re-run, clear this file's cache entry first
function M.review(opts)
  opts = opts or {}
  local ctx, err = get_review_context()
  if not ctx then
    if not opts.auto then vim.notify("DiffReview: " .. err, vim.log.levels.WARN) end
    return
  end

  local cache_key = make_cache_key(ctx)

  if opts.auto then
    if M._review_cache[cache_key] or M._in_progress[cache_key] then return end
  else
    -- Manual: force re-review, evict this file from cache
    M._review_cache[cache_key] = nil
    if M._in_progress[cache_key] then
      vim.notify("DiffReview: review already in progress", vim.log.levels.INFO)
      return
    end
  end

  local ok2, settings_local = pcall(require, "config.settings_local")
  local dr_cfg = (ok2 and type(settings_local) == "table" and settings_local.diff_review) or {}
  local claude_cmd = dr_cfg.claude_command or vim.fn.exepath("claude")
  if not claude_cmd or claude_cmd == "" then
    vim.notify("DiffReview: command not found — set diff_review.claude_command in settings_local.lua", vim.log.levels.ERROR)
    return
  end

  local diff = ctx.diff
  if #diff > MAX_DIFF_CHARS then diff = diff:sub(1, MAX_DIFF_CHARS) .. "\n[...truncated]" end

  local parts = { REVIEW_PROMPT, "" }
  if ctx.subjects then
    table.insert(parts, "Commits:"); table.insert(parts, ctx.subjects); table.insert(parts, "")
  end
  if ctx.file then
    table.insert(parts, "File: " .. ctx.file); table.insert(parts, "")
  end
  table.insert(parts, "```diff")
  table.insert(parts, diff)
  table.insert(parts, "```")
  local prompt = table.concat(parts, "\n")

  local scope = ctx.file and ctx.file:match("[^/]+$")
    or (ctx.info.left_display .. "→working tree")
  -- Auto-trigger: silent start; manual: always notify
  if not opts.auto then
    vim.notify("DiffReview: reviewing " .. scope .. "...", vim.log.levels.INFO)
  end

  -- For per-file reviews: clear only that file's old data, accumulate others
  local clear_pat = ctx.file  -- relative path substring; nil for whole-repo
  update_quickfix({}, clear_pat)
  apply_diagnostics({}, clear_pat)

  local root = ctx.info and ctx.info.root
  local entries = {}
  local partial = ""

  M._in_progress[cache_key] = true

  local debug = dr_cfg.debug == true
  local log_buf = nil
  if debug then
    log_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[log_buf].buftype = "nofile"
    vim.bo[log_buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_name(log_buf, "DiffReview:log")
    vim.cmd("botright 12split")
    vim.api.nvim_win_set_buf(0, log_buf)
    vim.cmd("wincmd p")
  end

  local function log_raw(lines)
    if not log_buf or not vim.api.nvim_buf_is_valid(log_buf) then return end
    vim.api.nvim_buf_set_lines(log_buf, -1, -1, false, lines)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == log_buf then
        pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(log_buf), 0 })
      end
    end
  end

  local function process_lines(raw_lines)
    local lines = { partial .. (raw_lines[1] or "") }
    for i = 2, #raw_lines do table.insert(lines, raw_lines[i]) end
    partial = table.remove(lines) or ""
    local added = false
    for _, line in ipairs(lines) do
      local entry = parse_loc_line(line, root)
      if entry then table.insert(entries, entry); added = true end
    end
    if added then
      update_quickfix(entries, clear_pat)
      apply_diagnostics(entries, clear_pat)
    end
  end

  local start_ms = vim.uv.now()
  local heartbeat = vim.uv.new_timer()
  heartbeat:start(5000, 5000, vim.schedule_wrap(function()
    local secs = math.floor((vim.uv.now() - start_ms) / 1000)
    vim.notify("DiffReview: " .. scope .. " (" .. secs .. "s)...", vim.log.levels.INFO)
  end))

  local cmd = { claude_cmd, "-p", "--no-session-persistence" }
  if dr_cfg.model then vim.list_extend(cmd, { "--model", dr_cfg.model }) end

  local env = vim.tbl_extend("force", vim.fn.environ(), { CLAUDECODE = "" }, dr_cfg.env or {})

  local stderr_buf = {}
  local job = vim.fn.jobstart(cmd, {
    env             = env,
    stdout_buffered = false,
    on_stdout = function(_, data) log_raw(data); process_lines(data) end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then table.insert(stderr_buf, line) end
      end
      log_raw(data)
    end,
    on_exit = function(_, code)
      pcall(function() heartbeat:stop(); heartbeat:close() end)
      M._in_progress[cache_key] = nil
      if partial ~= "" then
        local e = parse_loc_line(partial, root)
        if e then table.insert(entries, e) end
        partial = ""
      end
      update_quickfix(entries, clear_pat)
      apply_diagnostics(entries, clear_pat)
      -- Cache result (even if empty) so this file is not reviewed again
      M._review_cache[cache_key] = entries
      local n = #entries
      if code ~= 0 and n == 0 then
        local stderr_msg = #stderr_buf > 0 and ("\n" .. table.concat(stderr_buf, "\n")) or ""
        vim.notify("DiffReview: exited " .. code .. stderr_msg, vim.log.levels.ERROR)
        return
      end
      if n > 0 then
        local ls = {}
        for i, e in ipairs(entries) do
          table.insert(ls, ("  %d. %s:%d %s"):format(i, e.filename, e.lnum, e.text))
        end
        vim.notify("DiffReview: " .. scope .. " — " .. n .. " issue(s)\n" .. table.concat(ls, "\n"), vim.log.levels.WARN)
      else
        vim.notify("DiffReview: " .. scope .. " — no issues", vim.log.levels.INFO)
      end
    end,
  })

  if job <= 0 then
    M._in_progress[cache_key] = nil
    vim.notify("DiffReview: failed to start " .. claude_cmd, vim.log.levels.ERROR)
    return
  end

  vim.fn.chansend(job, prompt)
  vim.fn.chanclose(job, "stdin")
end

return M
