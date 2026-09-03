-- Findings recorded by a review that ran outside the editor, replayed onto the
-- gR diff as you open each file.
--
-- The review writes one file next to its notes in the ticket folder:
--
--     <tasks_dir>/<TICKET>/<name>findings.tsv
--     # repo: nbs-art-odata-api
--     # mr: 14
--     # head: 4d6af946e9844a63403ddc99671ae70ee70b4fcc
--     <repo-relative path><TAB><new-file line><TAB><message>
--
-- A review opened with gR or :ReviewMR finds its own file: by the ticket key in
-- the head ref (<tasks_dir>/NBSART-754/*findings.tsv), else by MR number
-- (<tasks_dir>/*/mr14-findings.tsv) — a source branch need not name its ticket.
--
-- Findings are scoped to ONE commit. `# head:` must equal the review's HEAD or
-- nothing is loaded: a branch that has moved on, or a sibling branch sharing the
-- ticket key, is a different tree and these line numbers would not describe it.
--
-- `:ReviewFindings [path]` activates one by hand, bypassing that check — no
-- argument picks the most recently written file under tasks_dir.
-- `:ReviewFindings!` clears the active file and its annotations.
--
-- review_view annotates each file as it is shown (⏎ in the sidebar): quickfix
-- entries + inline diagnostics, tagged `[review]`. Nothing is executed, so reading
-- a review never invokes a checker; `r` still runs the real ones on top.
local M = {}

-- The active review: file, findings by repo-relative path, the commit it was
-- written against, and the review key it was resolved for.
local state = { file = nil, by_path = {}, count = 0, head = nil, key = nil }
local tried = {}

local function tasks_root()
  local settings = require("config.settings")
  return vim.fn.expand(settings.get("tasks_dir", "~/sources/nbs-art/tasks"))
end

-- One of the file's `# key: value` headers, or nil.
local function header(file, key)
  for _, line in ipairs(vim.fn.readfile(file, "", 20)) do
    local v = line:match("^#%s*" .. key .. ":%s*(%S+)")
    if v then return v end
  end
  return nil
end

-- path<TAB>line<TAB>message, skipping blanks, comments and short rows.
local function parse(file)
  local by_path, count = {}, 0
  for _, line in ipairs(vim.fn.readfile(file)) do
    if not line:match("^%s*#") and not line:match("^%s*$") then
      local path, lnum, msg = line:match("^([^\t]+)\t(%d+)\t(.+)$")
      if path and lnum and msg then
        by_path[path] = by_path[path] or {}
        table.insert(by_path[path], { line = tonumber(lnum), msg = vim.trim(msg) })
        count = count + 1
      end
    end
  end
  for _, list in pairs(by_path) do
    table.sort(list, function(a, b) return a.line < b.line end)
  end
  return by_path, count
end

-- Ticket key (PROJ-123) carried by the review's head ref, if any.
local function ticket_of(head_ref)
  return head_ref and head_ref:match("%f[%u]%u%u+%-%d+") or nil
end

-- Best file matching a glob under tasks_dir whose declared repo does not
-- contradict this review, or nil. Two repos can both have an MR !14, so the
-- `# repo:` header is what keeps `*/mr14-findings.tsv` off the wrong one.
-- Header-less files match anything, so older files keep working.
--
-- A file written against the commit being reviewed wins over a newer one written
-- against a different commit: a ticket accumulates a findings file per review round,
-- and mtime alone would hand back the wrong round and reject it.
local function newest(glob, repo, head)
  local found = vim.fn.globpath(tasks_root(), glob, false, true)
  table.sort(found, function(a, b) return vim.fn.getftime(a) > vim.fn.getftime(b) end)
  local fallback
  for _, f in ipairs(found) do
    local declared = header(f, "repo")
    if not declared or not repo or declared == repo then
      local h = header(f, "head")
      if head and h and (vim.startswith(head, h) or vim.startswith(h, head)) then return f end
      fallback = fallback or f
    end
  end
  return fallback
end

-- How a findings file relates to the review in front of you, decided by git rather
-- than by the ticket key: one ticket has many branches.
--   "same"      the review is exactly the commit the findings were written against
--   "ancestor"  same line of work, but the branch has moved on
--   "unrelated" another branch, or history was rewritten
--   "unknown"   the file declares no head
local function relation(root, declared, head)
  if not (declared and root and head) then return "unknown" end
  if vim.startswith(head, declared) or vim.startswith(declared, head) then return "same" end
  local G = require("config.git")
  if not G.run(root, { "cat-file", "-e", declared .. "^{commit}" }) then return "unrelated" end
  if G.run(root, { "merge-base", "--is-ancestor", declared, head }) then return "ancestor" end
  return "unrelated"
end

-- Every *findings.tsv under tasks_dir, most recently modified first.
function M.candidates()
  local root = tasks_root()
  if vim.fn.isdirectory(root) == 0 then return {} end
  local found = vim.fn.globpath(root, "**/*findings.tsv", false, true)
  table.sort(found, function(a, b) return vim.fn.getftime(a) > vim.fn.getftime(b) end)
  return found
end

-- The findings file a review should use, without prompting:
--   <tasks_dir>/<TICKET>/*findings.tsv   when the head ref carries a ticket key
--   <tasks_dir>/*/mr<iid>-findings.tsv   when the review came from :ReviewMR
function M.resolve(ctx)
  ctx = ctx or {}
  local ticket = ticket_of(ctx.head_ref)
  if ticket then
    local hit = newest(ticket .. "/*findings.tsv", ctx.repo, ctx.head)
    if hit then return hit, ticket end
  end
  if ctx.mr_iid then
    local hit = newest(("*/mr%d-findings.tsv"):format(ctx.mr_iid), ctx.repo, ctx.head)
    if hit then return hit, ("!%d"):format(ctx.mr_iid) end
  end
  return nil
end

function M.active() return state.file end

function M.clear()
  state = { file = nil, by_path = {}, count = 0, head = nil, key = nil }
  tried = {}
end

-- Findings for one repo-relative path: a (possibly empty) list while a review is
-- active, nil when none is — which is how review_view tells "nothing to show here"
-- from "not showing a review at all".
function M.for_file(path)
  if not state.file then return nil end
  return state.by_path[path] or {}
end

-- Activate a findings file. Empty/omitted path = the newest one under tasks_dir.
function M.load(path)
  if path == nil or path == "" then
    local found = M.candidates()
    if #found == 0 then
      vim.notify("ReviewFindings: no *findings.tsv under " .. tasks_root(), vim.log.levels.WARN)
      return false
    end
    path = found[1]
  end
  path = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  if vim.fn.filereadable(path) == 0 then
    vim.notify("ReviewFindings: cannot read " .. path, vim.log.levels.ERROR)
    return false
  end

  local by_path, count = parse(path)
  if count == 0 then
    vim.notify("ReviewFindings: no findings parsed from " .. vim.fn.fnamemodify(path, ":t")
      .. "\nExpected: <path><TAB><line><TAB><message>", vim.log.levels.WARN)
    return false
  end

  state = { file = path, by_path = by_path, count = count, head = header(path, "head"), key = nil }
  vim.notify(("ReviewFindings: %d finding(s) across %d file(s) from %s")
    :format(count, vim.tbl_count(by_path), vim.fn.fnamemodify(path, ":t")), vim.log.levels.INFO)
  return true
end

-- Resolve and activate once per review+commit. A miss is remembered so opening
-- file after file does not rescan the tasks tree.
function M.auto(ctx)
  ctx = ctx or {}
  local key = (ctx.repo or "") .. "@" .. (ctx.head or ctx.head_ref or "")
    .. "#" .. tostring(ctx.mr_iid)
  if state.key == key then return end
  -- Findings resolved for a DIFFERENT review+commit are stale here: retire them
  -- before deciding what this one gets, so a commit that no longer matches ends up
  -- with no findings rather than with the previous commit's. A file activated by
  -- hand (:ReviewFindings, state.key nil) is deliberate and stays put.
  if state.key and state.file then M.clear() end
  if tried[key] then return end
  tried[key] = true

  local file, how = M.resolve(ctx)
  if not file then return end

  local declared = header(file, "head")
  local rel = relation(ctx.root, declared, ctx.head)
  if rel ~= "same" then
    local name = vim.fn.fnamemodify(file, ":t")
    local why
    if rel == "ancestor" then
      why = ("%s was written against %s, this review is %s — re-run the review")
        :format(name, (declared or ""):sub(1, 8), (ctx.head or ""):sub(1, 8))
    elseif rel == "unknown" then
      why = ("%s records no `# head:` commit"):format(name)
    else
      why = ("%s belongs to commit %s, not this branch"):format(name, (declared or "?"):sub(1, 8))
    end
    vim.notify(("ReviewFindings: not loaded — %s.\nLoad it anyway with :ReviewFindings %s")
      :format(why, vim.fn.fnamemodify(file, ":~")), vim.log.levels.INFO)
    return
  end

  if not M.load(file) then return end
  state.key = key
  vim.notify("ReviewFindings: matched " .. how, vim.log.levels.INFO)
end

-- Re-apply to whatever the review is showing, so activating mid-review lights up
-- the current file without reselecting it.
local function refresh_current()
  local ok, rv = pcall(require, "config.review_view")
  if ok and rv.reapply_findings then pcall(rv.reapply_findings) end
end

function M.setup()
  vim.api.nvim_create_user_command("ReviewFindings", function(o)
    if o.bang then
      M.clear()
      refresh_current()
      vim.notify("ReviewFindings: cleared", vim.log.levels.INFO)
      return
    end
    if M.load(o.args) then refresh_current() end
  end, {
    nargs = "?",
    bang = true,
    complete = "file",
    desc = "Load review findings (tasks/<TICKET>/*findings.tsv) into the gR review; ! clears",
  })
end

return M
