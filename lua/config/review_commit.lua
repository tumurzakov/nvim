-- review_commit: the commit step of the review view (gR `c`).
--
-- Collects everything uncommitted in the working tree, has the configured AI CLI
-- (settings_local.diff_review, same one the review checkers use) draft a commit
-- message from that diff, shows it in an editable float for confirmation, and on
-- ⏎ stages the whole tree and commits.
local M = {}

local settings = require("config.settings")
local G = require("config.git")

-- Cap on the diff handed to the AI. Big enough for a normal commit; a runaway
-- diff gets cut at a line boundary so no token is split mid-way.
local MAX_DIFF_CHARS = 24000

local PROMPT = [[Write the git commit message for the change below.
Subject line: Conventional Commits — <type>(<scope>): <summary> — at most 72
characters, imperative mood, no trailing period. Scope is optional; use it only
when the change is confined to one clear area.
If the change needs explanation, add a blank line and 1-3 short "- " bullets
saying WHY it was made, not restating what the diff shows. If it is
self-explanatory, the subject alone is the whole message.
Describe only what the diff actually changes — do not speculate about intent
beyond what the code supports.
Output the message and nothing else: no preamble, no code fences, no quotes.]]

-- `git status --porcelain` rows — exactly what the commit will pick up, shown to
-- the user as comment lines so `c` never commits something unseen.
local function status_rows(root)
  local ok, out = G.run(root, { "status", "--porcelain" })
  local rows = {}
  if ok then
    for _, l in ipairs(out) do if l ~= "" then rows[#rows + 1] = l end end
  end
  return rows
end

-- The change as one diff: tracked edits vs `from`, plus the full contents of each
-- untracked file (which `git diff` cannot see). `from` is HEAD for a new commit,
-- or HEAD's parent for an amend — there the diff must cover the commit being
-- rewritten as well as the edits being folded into it.
local function working_diff(root, from)
  local parts = {}
  local ok, out = G.run(root, { "diff", from })
  if ok and #out > 0 then parts[#parts + 1] = table.concat(out, "\n") end
  local uok, untracked = G.run(root, { "ls-files", "--others", "--exclude-standard" })
  if uok then
    for _, path in ipairs(untracked) do
      if path ~= "" then
        -- --no-index exits 1 when the files differ (always, here), so ignore the code
        parts[#parts + 1] = table.concat(vim.fn.systemlist({
          "git", "-C", root, "diff", "--no-index", "--", "/dev/null", path,
        }), "\n")
      end
    end
  end
  local diff = table.concat(parts, "\n")
  if #diff > MAX_DIFF_CHARS then
    diff = diff:sub(1, MAX_DIFF_CHARS)
    diff = diff:sub(1, (diff:match(".*()\n") or (#diff + 1)) - 1) .. "\n[... diff truncated for length ...]"
  end
  return diff
end

-- Strip the code fence an AI sometimes wraps the message in, plus stray blanks.
local function clean(text)
  local lines = vim.split(vim.trim(text), "\n", { plain = true })
  if lines[1] and lines[1]:match("^```") then table.remove(lines, 1) end
  if lines[#lines] and lines[#lines]:match("^```") then table.remove(lines) end
  return vim.trim(table.concat(lines, "\n"))
end

-- The parent of HEAD, or the empty tree when HEAD is the repo's root commit — the
-- left side of an amend's diff.
local EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
local function head_parent(root)
  local ok, out = G.run(root, { "rev-parse", "--verify", "--quiet", "HEAD^" })
  return (ok and out[1] and out[1] ~= "") and out[1] or EMPTY_TREE
end

-- HEAD's own commit message, as one string.
local function head_message(root)
  local ok, out = G.run(root, { "log", "-1", "--format=%B" })
  return ok and vim.trim(table.concat(out, "\n")) or ""
end

-- Is HEAD already on the remote feature branch? Amending then rewrites published
-- history, so the next push has to be forced — worth saying out loud beforehand.
-- Returns the upstream name when it is, else nil.
local function pushed_upstream(root)
  local ok, out = G.run(root, { "rev-parse", "--abbrev-ref", "@{u}" })
  if not (ok and out[1] and out[1] ~= "") then return nil end
  if not G.run(root, { "merge-base", "--is-ancestor", "HEAD", "@{u}" }) then return nil end
  return out[1]
end

-- Stage the whole tree and commit. `add -A` matches what the review lists (every
-- change in the tree), so the commit holds no surprises relative to the sidebar.
-- opts.amend rewrites HEAD instead of adding a commit; `msg` nil then means
-- --no-edit (keep HEAD's message, just fold the tree in).
local function do_commit(root, msg, opts)
  local add = vim.system({ "git", "-C", root, "add", "-A" }, { text = true }):wait()
  if add.code ~= 0 then
    vim.notify("review_commit: git add failed:\n" .. vim.trim((add.stderr or "") .. (add.stdout or "")),
      vim.log.levels.ERROR)
    return
  end
  local args = { "git", "-C", root, "commit" }
  if opts.amend then args[#args + 1] = "--amend" end
  if msg then vim.list_extend(args, { "-F", "-" }) else args[#args + 1] = "--no-edit" end
  local verb = opts.amend and "amended" or "committed"
  vim.system(args, { text = true, stdin = msg }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        vim.notify(("review_commit: %s failed:\n%s"):format(opts.amend and "amend" or "commit",
          vim.trim((res.stderr or "") .. (res.stdout or ""))), vim.log.levels.ERROR)
        return
      end
      local ok, out = G.run(root, { "log", "-1", "--format=%h %s" })
      vim.notify(("review_commit: %s %s"):format(verb, (ok and out[1]) or ""), vim.log.levels.INFO)
      if opts.after_warn then vim.notify(opts.after_warn, vim.log.levels.WARN) end
      if opts.on_done then opts.on_done() end
    end)
  end)
end

-- The confirmation float: the drafted message on top, the staged-file list below
-- as `#` comments (dropped before committing, like a real git commit template).
local function open_editor(root, msg, rows, opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "gitcommit"

  local lines = vim.split(msg ~= "" and msg or "", "\n", { plain = true })
  vim.list_extend(lines, {
    "",
    ("# ⏎ or <C-s> %s  ·  q / <Esc> cancel  ·  edit freely; # lines are dropped"):format(
      opts.amend and "amend" or "commit"),
  })
  if opts.amend then
    table.insert(lines, ("# amending %s on %s — %d path(s) folded in%s"):format(
      opts.amend_of or "HEAD", opts.branch or "HEAD", #rows, #rows == 0 and " (reword only)" or ":"))
  else
    table.insert(lines, ("# on %s — %d path(s) will be staged and committed:"):format(
      opts.branch or "HEAD", #rows))
  end
  for _, r in ipairs(rows) do lines[#lines + 1] = "#   " .. r end
  -- Keep the message being replaced in view: an amend often only needs a tweak of
  -- the original, and once the buffer is overwritten it is otherwise gone.
  if opts.amend and opts.old_msg and opts.old_msg ~= "" then
    table.insert(lines, "#")
    table.insert(lines, "# original message:")
    for _, l in ipairs(vim.split(opts.old_msg, "\n", { plain = true })) do lines[#lines + 1] = "#   " .. l end
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local width = math.min(96, math.max(60, vim.o.columns - 8))
  local height = math.min(#lines + 1, math.max(8, vim.o.lines - 6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = opts.amend and " amend message " or " commit message ",
    title_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })

  local o = { buffer = buf, nowait = true, silent = true }
  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end
  local function confirm()
    local kept = {}
    for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if not l:match("^%s*#") then kept[#kept + 1] = l end
    end
    local final = vim.trim(table.concat(kept, "\n"))
    if final == "" then
      vim.notify("review_commit: empty message — nothing committed", vim.log.levels.WARN)
      return
    end
    close()
    do_commit(root, final, opts)
  end
  vim.keymap.set("n", "<CR>", confirm, o)
  vim.keymap.set({ "n", "i" }, "<C-s>", confirm, o)
  vim.keymap.set("n", "q", close, o)
  vim.keymap.set("n", "<Esc>", close, o)
end

-- Draft a message and open the confirmation float.
--   opts.branch   branch name shown in the float header
--   opts.amend    rewrite HEAD (message covers HEAD's change + the working tree)
--   opts.on_done  called after a successful commit (the review refreshes)
function M.commit(root, opts)
  opts = opts or {}
  local rows = status_rows(root)
  -- A clean tree is still a valid amend (reword only), but there is nothing to
  -- turn into a new commit.
  if #rows == 0 and not opts.amend then
    vim.notify("review_commit: nothing to commit — the working tree is clean", vim.log.levels.INFO)
    return
  end

  local parts = { PROMPT, "" }
  local sok, subjects = G.run(root, { "log", (opts.amend and "-n11" or "-n10"), "--format=%s" })
  if sok and #subjects > 0 then
    -- On an amend, HEAD's own subject is the one being replaced — showing it as a
    -- style example would just invite the AI to echo it back.
    if opts.amend then table.remove(subjects, 1) end
    if #subjects > 0 then
      table.insert(parts, "Recent subjects in this repo, for style:")
      for _, s in ipairs(subjects) do table.insert(parts, "- " .. s) end
      table.insert(parts, "")
    end
  end
  if opts.amend then
    table.insert(parts, "This REPLACES an existing commit, whose message was:")
    for _, l in ipairs(vim.split(opts.old_msg or "", "\n", { plain = true })) do
      table.insert(parts, "  " .. l)
    end
    table.insert(parts, "")
    table.insert(parts, "Write the message for the COMBINED change below — that commit plus the")
    table.insert(parts, "edits now being folded into it. Reuse the original wording where it still")
    table.insert(parts, "fits; do not mention that the commit was amended.")
    table.insert(parts, "")
    table.insert(parts, "Diff of the combined change:")
  else
    table.insert(parts, "Diff of the uncommitted change:")
  end
  table.insert(parts, "```diff")
  table.insert(parts, working_diff(root, opts.amend and head_parent(root) or "HEAD"))
  table.insert(parts, "```")

  local cmd, env = settings.ai_command()
  local acc = {}
  vim.notify(("review_commit: drafting %s message for %d path(s)…"):format(
    opts.amend and "an amended" or "a commit", #rows), vim.log.levels.INFO)
  require("config.agent_runner").run_cmd(cmd, {
    label = "commit-msg",
    env = env,
    stdin = table.concat(parts, "\n"),
    on_line = function(line) acc[#acc + 1] = line end,
    on_exit = function(code, stderr)
      vim.schedule(function()
        local msg = clean(table.concat(acc, "\n"))
        if code ~= 0 or msg == "" then
          -- Still open the editor: writing the message by hand beats losing the
          -- flow. An amend starts from the message it is replacing, so a failed
          -- draft costs a tweak rather than a retype.
          vim.notify("review_commit: no message from the AI — write one yourself"
            .. ((stderr and stderr ~= "") and ("\n" .. stderr) or ""), vim.log.levels.WARN)
          msg = opts.amend and (opts.old_msg or "") or ""
        end
        open_editor(root, msg, rows, opts)
      end)
    end,
  })
end

-- Fold the working tree into HEAD. Asks first, offering either a re-drafted
-- message (the AI sees HEAD's change and the new edits as one change) or keeping
-- HEAD's message untouched.
--   opts.branch   branch name shown in the confirm dialog and float header
--   opts.on_done  called after a successful amend (the review refreshes)
function M.amend(root, opts)
  opts = opts or {}
  local ok, head = G.run(root, { "log", "-1", "--format=%h %s" })
  if not (ok and head[1] and head[1] ~= "") then
    vim.notify("review_commit: no commit to amend", vim.log.levels.WARN)
    return
  end
  local rows = status_rows(root)
  local upstream = pushed_upstream(root)
  local warn = upstream and ("\n  ⚠ already pushed to " .. upstream .. " — amending rewrites it,"
    .. "\n    so the next push must be forced (P offers Force-push).") or ""
  local folding = (#rows == 0) and "reword only — the tree is clean"
    or ("fold in %d uncommitted path(s)"):format(#rows)

  local choice = vim.fn.confirm(("Amend %s?\n  %s%s"):format(head[1], folding, warn),
    "&Reword (AI)\n&Keep message\n&Cancel", 1)
  if choice ~= 1 and choice ~= 2 then return end

  local shared = vim.tbl_extend("force", opts, {
    amend = true,
    amend_of = head[1],
    old_msg = head_message(root),
    after_warn = upstream and ("review_commit: " .. head[1] .. " was rewritten but is already on "
      .. upstream .. " — push with Force (P) or the remote will reject it.") or nil,
  })
  if choice == 1 then
    M.commit(root, shared)
  else
    do_commit(root, nil, shared)   -- --no-edit: keep HEAD's message verbatim
  end
end

return M
