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

function M.review(arg)
  arg = vim.trim(arg or "")
  if arg == "" then arg = vim.trim(vim.fn.getreg("+") or "") end     -- fall back to clipboard
  if arg == "" then arg = vim.trim(vim.fn.getreg('"') or "") end     -- then the unnamed register

  local _, path, iid = parse(arg)
  if not iid then
    vim.notify("ReviewMR: give a GitLab MR URL or number (got: " .. arg .. ")", vim.log.levels.ERROR)
    return
  end

  local root = repo_root()
  if not root then
    vim.notify("ReviewMR: not inside a git repository", vim.log.levels.ERROR)
    return
  end

  local ok_o, origin = git(root, { "remote", "get-url", "origin" })
  origin = ok_o and origin[1] or ""
  if path and not origin:find(path, 1, true) then
    vim.notify(("ReviewMR: this repo's origin (%s)\ndoes not match the MR project '%s'."):format(origin, path),
      vim.log.levels.ERROR)
    return
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
  vim.notify(("ReviewMR: reviewing !%d on '%s' vs '%s'"):format(iid, branch, base), vim.log.levels.INFO)
end

vim.api.nvim_create_user_command("ReviewMR", function(o) M.review(o.args) end, {
  nargs = "?",
  desc = "Review a GitLab MR by URL/number (fetch MR head, gR vs develop)",
})

return M
