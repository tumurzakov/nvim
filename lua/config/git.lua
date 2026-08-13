-- Shared synchronous git helpers. One home for the runner, root/remote/base
-- resolution, and ahead/behind parsing that were previously copy-pasted across
-- review_view, review_mr, tree_git_switch and tree_git_popup.
local M = {}

local settings = require("config.settings")

-- Run git in `root`; returns ok, output lines.
function M.run(root, args)
  local cmd = { "git", "-C", root }
  vim.list_extend(cmd, args)
  local out = vim.fn.systemlist(cmd)
  return vim.v.shell_error == 0, out
end

-- The remote to fetch/push against. Configurable via settings_local.git_remote.
function M.remote()
  return settings.remote()
end

-- Configured base branch; callers pass their own default (sites differ on purpose).
function M.base_branch(default)
  return settings.base_branch(default)
end

-- Toplevel of the repo containing `dir`, or nil.
function M.root(dir)
  local ok, out = M.run(dir, { "rev-parse", "--show-toplevel" })
  if ok and out[1] and out[1] ~= "" then return out[1] end
  return nil
end

-- Directory of the current buffer's file, else the cwd — the usual starting
-- point for repo lookups from a keymap/command.
function M.buf_dir()
  local file = vim.api.nvim_buf_get_name(0)
  if file ~= "" and vim.fn.filereadable(file) == 1 then
    return vim.fn.fnamemodify(file, ":h")
  end
  return vim.fn.getcwd()
end

-- Human repo name: the origin project name (works even for a temp worktree whose
-- toplevel dir is a random tempname), falling back to the root's basename.
function M.repo_name(root)
  local ok, url = M.run(root, { "remote", "get-url", M.remote() })
  if ok and url[1] and url[1] ~= "" then
    local n = url[1]:gsub("%.git$", ""):match("([^/:]+)$")
    if n and n ~= "" then return n end
  end
  return vim.fn.fnamemodify(root, ":t")
end

-- A set of path names from a `git` name-only command.
function M.name_set(root, args)
  local ok, out = M.run(root, args)
  local s = {}
  if ok then for _, l in ipairs(out) do if l ~= "" then s[l] = true end end end
  return s
end

-- behind, ahead of `range` (e.g. "@{u}...HEAD"), both 0 on failure.
function M.ahead_behind(root, range)
  local ok, out = M.run(root, { "rev-list", "--left-right", "--count", range })
  local behind, ahead = 0, 0
  if ok and out[1] then behind, ahead = out[1]:match("(%d+)%s+(%d+)") end
  return tonumber(behind) or 0, tonumber(ahead) or 0
end

-- Ahead/behind of HEAD vs its upstream (the REMOTE feature branch, e.g.
-- origin/my-feature) — i.e. whether local commits need pushing (ahead) or the
-- remote has commits to pull (behind). No network: compares against the last-known
-- remote-tracking ref, so "to push" is always accurate; "to pull" may be stale
-- until a fetch.
function M.upstream_status(root)
  local uok, uout = M.run(root, { "rev-parse", "--abbrev-ref", "@{u}" })
  local name = (uok and uout[1] and uout[1] ~= "") and uout[1] or nil
  if not name then return { has_upstream = false } end
  local behind, ahead = M.ahead_behind(root, "@{u}...HEAD")
  return { has_upstream = true, name = name, behind = behind, ahead = ahead }
end

-- Resolve the diffing base ref: try git_base_branch, then main/master/develop and
-- their <remote>/ variants, finally <remote>/HEAD. Returns ref, git_base.
function M.resolve_base(root)
  local git_base = M.base_branch("main")
  local remote = M.remote()
  local function verify(ref)
    local ok = M.run(root, { "rev-parse", "--verify", "--quiet", ref })
    return ok
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
  local okh, out = M.run(root, { "symbolic-ref", "--short", "refs/remotes/" .. remote .. "/HEAD" })
  if okh and out[1] and out[1] ~= "" then return out[1], git_base end
  return nil, git_base
end

return M
