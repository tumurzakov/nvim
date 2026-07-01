-- :ReviewMR <gitlab-mr-url|iid>
--
-- Paste a GitLab merge-request URL (e.g.
--   https://eu.git.epam.com/group/project/-/merge_requests/34 )
-- and it fetches the MR's head from origin (tokenless, via GitLab's
-- refs/merge-requests/<iid>/head), checks it out as a local `mr-<iid>` branch,
-- then opens the gR review view — which diffs it against the base (develop).
local M = {}

-- host, "group/sub/project", iid  ← from a full MR URL; or nil,nil,iid for a bare number.
local function parse(arg)
  arg = vim.trim(arg or "")
  if arg:match("^%d+$") then return nil, nil, tonumber(arg) end
  local host, path, iid = arg:match("^https?://([^/]+)/(.-)/%-/merge_requests/(%d+)")
  return host, path, iid and tonumber(iid)
end

local function base_branch()
  local ok, sl = pcall(require, "config.settings_local")
  return (ok and type(sl) == "table" and sl.git_base_branch) or "develop"
end

local function repo_root()
  local file = vim.api.nvim_buf_get_name(0)
  local dir = (file ~= "" and vim.fn.filereadable(file) == 1)
    and vim.fn.fnamemodify(file, ":h") or vim.fn.getcwd()
  local out = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 or not out[1] or out[1] == "" then return nil end
  return out[1]
end

local function git(root, args)
  local cmd = { "git", "-C", root }
  vim.list_extend(cmd, args)
  local out = vim.fn.systemlist(cmd)
  return vim.v.shell_error == 0, out
end

-- If `dir` is inside a git repo whose origin contains the MR project `path`,
-- return that repo's toplevel; else nil.
local function origin_matches(dir, path)
  local ok, top = git(dir, { "rev-parse", "--show-toplevel" })
  if not ok or not top[1] or top[1] == "" then return nil end
  local ok2, o = git(top[1], { "remote", "get-url", "origin" })
  if ok2 and o[1] and o[1]:find(path, 1, true) then return top[1] end
  return nil
end

-- Locate the local clone for MR project `path` (e.g. "nbs-art/nbs-art-…"):
-- 1) the repo we're already in, 2) <root>/<repo-name>, 3) any immediate subdir.
-- Roots = the cwd plus any settings_local.review_mr_roots.
local function find_repo(path)
  local file = vim.api.nvim_buf_get_name(0)
  local here = (file ~= "" and vim.fn.filereadable(file) == 1)
    and vim.fn.fnamemodify(file, ":h") or vim.fn.getcwd()
  local r = origin_matches(here, path)
  if r then return r end

  local roots = { vim.fn.getcwd() }
  local ok, sl = pcall(require, "config.settings_local")
  if ok and type(sl) == "table" and type(sl.review_mr_roots) == "table" then
    for _, x in ipairs(sl.review_mr_roots) do roots[#roots + 1] = vim.fn.expand(x) end
  end

  local name = path:match("([^/]+)$")   -- fast path: <root>/<repo-name>
  for _, root in ipairs(roots) do
    if name and vim.fn.isdirectory(root .. "/" .. name) == 1 then
      r = origin_matches(root .. "/" .. name, path)
      if r then return r end
    end
  end

  for _, root in ipairs(roots) do       -- otherwise scan one level of subdirs
    local okd, it = pcall(vim.fs.dir, root)
    if okd then
      for entry, typ in it do
        if typ == "directory" and vim.fn.isdirectory(root .. "/" .. entry .. "/.git") == 1 then
          r = origin_matches(root .. "/" .. entry, path)
          if r then return r end
        end
      end
    end
  end
  return nil
end

function M.review(arg)
  arg = vim.trim(arg or "")
  if arg == "" then arg = vim.trim(vim.fn.getreg("+") or "") end     -- fall back to clipboard
  if arg == "" then arg = vim.trim(vim.fn.getreg('"') or "") end     -- then the unnamed register

  local _, path, iid = parse(arg)
  if not iid then
    vim.notify("ReviewMR: give a GitLab MR URL or number (got: " .. arg .. ")", vim.log.levels.ERROR)
    return
  end

  local root
  if path then
    root = find_repo(path)
    if not root then
      vim.notify(("ReviewMR: no local clone of '%s' found.\nStart nvim from its parent (e.g. ~/sources/nbs-art) "
        .. "or add its root to review_mr_roots in settings_local."):format(path), vim.log.levels.ERROR)
      return
    end
  else
    root = repo_root()   -- bare number: assume we're already in the repo
    if not root then
      vim.notify("ReviewMR: not inside a git repo — paste the full MR URL so I can find it", vim.log.levels.ERROR)
      return
    end
  end

  -- Guard the user's uncommitted work: checking out the MR would move HEAD.
  local _, dirty = git(root, { "status", "--porcelain" })
  if #dirty > 0 then
    if vim.fn.confirm("Working tree has uncommitted changes.\nChecking out the MR will move HEAD. Continue?",
      "&No\n&Yes", 1) ~= 2 then
      return
    end
  end

  local base = base_branch()
  vim.notify(("ReviewMR: fetching merge request !%d ..."):format(iid), vim.log.levels.INFO)

  -- 1) fetch the MR head (GitLab exposes it at refs/merge-requests/<iid>/head)
  local ok_f, out_f = git(root, { "fetch", "origin", ("merge-requests/%d/head"):format(iid) })
  if not ok_f then
    vim.notify("ReviewMR: fetch failed:\n" .. table.concat(out_f, "\n"), vim.log.levels.ERROR)
    return
  end
  local ok_s, sha = git(root, { "rev-parse", "FETCH_HEAD" })
  if not ok_s or not sha[1] then
    vim.notify("ReviewMR: could not resolve fetched MR head", vim.log.levels.ERROR)
    return
  end
  sha = sha[1]

  -- 2) refresh the base so the review diffs against an up-to-date develop
  git(root, { "fetch", "origin", base })

  -- 3) check the MR head out as a local branch
  local branch = "mr-" .. iid
  local ok_c, out_c = git(root, { "checkout", "-B", branch, sha })
  if not ok_c then
    vim.notify("ReviewMR: checkout failed:\n" .. table.concat(out_c, "\n"), vim.log.levels.ERROR)
    return
  end

  -- 4) open the red/green review view (diffs branch vs base)
  local rv = require("config.review_view")
  pcall(rv.close)
  rv.open(root)
  vim.notify(("ReviewMR: reviewing !%d on '%s' vs '%s' (%s)"):format(
    iid, branch, base, vim.fn.fnamemodify(root, ":t")), vim.log.levels.INFO)
end

vim.api.nvim_create_user_command("ReviewMR", function(o) M.review(o.args) end, {
  nargs = "?",
  desc = "Review a GitLab MR by URL/number (fetch MR head, gR vs develop)",
})

return M
