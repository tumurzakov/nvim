local M = {}

local MAX_DIFF_CHARS = 7000
local NS = vim.api.nvim_create_namespace("diff_review")
M._pending_diags = {}

local REVIEW_PROMPT = [[Review this diff for bugs, type errors, logic errors, security issues.
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

local function parse_loc_line(line, root)
  local file, lnum, msg = line:match("^LOC:%s*([^:]+):(%d+)%s+(.+)")
  if not (file and lnum) then return nil end
  local path = (root and not file:match("^/")) and (root .. "/" .. file) or file
  return { filename = path, lnum = tonumber(lnum), col = 1, text = msg, type = "W" }
end

-- Find all buffers for a filepath: exact match + diffview git-object buffers
-- (diffview names them with the path embedded, e.g. diffview://HEAD/src/foo.lua)
local function bufs_for_file(filepath)
  local found = {}
  local seen = {}
  local function add(b)
    if b > 0 and vim.api.nvim_buf_is_valid(b) and not seen[b] then
      seen[b] = true; table.insert(found, b)
    end
  end
  add(vim.fn.bufnr(filepath))
  -- last two path components as a unique-enough suffix
  local suffix = filepath:match("[^/]+/[^/]+$") or filepath:match("[^/]+$")
  if suffix then
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):find(suffix, 1, true) then add(b) end
    end
  end
  return found
end

local function apply_diagnostics(entries)
  M._pending_diags = {}
  vim.diagnostic.reset(NS)
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

-- Apply pending diagnostics when any buffer is read or enters a window
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

-- `<leader>cr` in diffview panel reviews the file under cursor
vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("DiffReviewPanel", { clear = true }),
  pattern = { "DiffviewFiles", "DiffviewFileHistory" },
  callback = function(ev)
    vim.keymap.set("n", "<leader>cr", function()
      require("config.diff_review").review()
    end, { buffer = ev.buf, desc = "DiffReview: review file under cursor" })
  end,
})

function M.clear()
  M._pending_diags = {}
  vim.diagnostic.reset(NS)
  vim.fn.setqflist({}, "r", { title = "DiffReview", items = {} })
  vim.notify("DiffReview: cleared", vim.log.levels.INFO)
end

function M.review()
  local ctx, err = get_review_context()
  if not ctx then
    vim.notify("DiffReview: " .. err, vim.log.levels.WARN)
    return
  end

  local ok, settings_local = pcall(require, "config.settings_local")
  local dr_cfg = (ok and type(settings_local) == "table" and settings_local.diff_review) or {}
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
  vim.notify("DiffReview: reviewing " .. scope .. "...", vim.log.levels.INFO)
  vim.fn.setqflist({}, "r", { title = "DiffReview (running...)", items = {} })
  M._pending_diags = {}
  vim.diagnostic.reset(NS)

  local root = ctx.info and ctx.info.root
  local entries = {}
  local partial = ""

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
      vim.fn.setqflist({}, "r", { title = "DiffReview", items = entries })
      apply_diagnostics(entries)
      vim.notify("DiffReview: " .. #entries .. " issue(s)...", vim.log.levels.INFO)
    end
  end

  local start_ms = vim.uv.now()
  local heartbeat = vim.uv.new_timer()
  heartbeat:start(5000, 5000, vim.schedule_wrap(function()
    local secs = math.floor((vim.uv.now() - start_ms) / 1000)
    vim.notify("DiffReview: still running (" .. secs .. "s)...", vim.log.levels.INFO)
  end))

  local cmd = { claude_cmd, "-p", "--no-session-persistence" }
  if dr_cfg.model then vim.list_extend(cmd, { "-m", dr_cfg.model }) end

  local env = vim.tbl_extend("force", vim.fn.environ(), { CLAUDECODE = "" }, dr_cfg.env or {})

  local job = vim.fn.jobstart(cmd, {
    env             = env,
    stdout_buffered = false,
    on_stdout = function(_, data) log_raw(data); process_lines(data) end,
    on_stderr = function(_, data)
      local msg = table.concat(data, "\n"):gsub("%s+$", "")
      if msg ~= "" then log_raw(data) end
    end,
    on_exit = function(_, code)
      pcall(function() heartbeat:stop(); heartbeat:close() end)
      if partial ~= "" then
        local e = parse_loc_line(partial, root)
        if e then table.insert(entries, e) end
        partial = ""
      end
      vim.fn.setqflist({}, "r", { title = "DiffReview", items = entries })
      apply_diagnostics(entries)
      local n = #entries
      if code ~= 0 and n == 0 then
        vim.notify("DiffReview: process exited with code " .. code, vim.log.levels.ERROR)
        return
      end
      if n > 0 then
        local lines = {}
        for i, e in ipairs(entries) do
          table.insert(lines, ("  %d. %s:%d %s"):format(i, e.filename, e.lnum, e.text))
        end
        vim.notify("DiffReview: " .. n .. " issue(s)\n" .. table.concat(lines, "\n"), vim.log.levels.WARN)
      else
        vim.notify("DiffReview: no issues found", vim.log.levels.INFO)
      end
    end,
  })

  if job <= 0 then
    vim.notify("DiffReview: failed to start " .. claude_cmd, vim.log.levels.ERROR)
    return
  end

  vim.fn.chansend(job, prompt)
  vim.fn.chanclose(job, "stdin")
end

return M
