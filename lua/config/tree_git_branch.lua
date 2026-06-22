-- Show the git branch next to folders in nvim-tree that are git work-tree roots.
--
-- The branch is read straight from `<dir>/.git/HEAD` (no `git` subprocess), so
-- it's cheap enough to run for every folder on every render — at any depth, and
-- it updates as you expand the tree. Results are cached per folder and only
-- re-read when HEAD's mtime changes, so a checkout in another window is picked
-- up but a static tree costs almost nothing. Because there's no subprocess, a
-- separate on-disk cache of "which folders are repos" isn't needed.
local M = {}

local uv = vim.uv or vim.loop

-- cache[dir] = { mtime = <HEAD mtime sec>, headpath = <str>, branch = <str|nil> }
local cache = {}

-- Path to the HEAD file for a repo whose work-tree root is `dir`, or nil if
-- `dir` is not a repo root. Handles both a `.git` directory (normal repo) and a
-- `.git` file containing `gitdir: <path>` (worktrees / submodules).
local function head_file(dir)
  local dotgit = dir .. "/.git"
  local stat = uv.fs_stat(dotgit)
  if not stat then return nil end
  if stat.type == "directory" then
    return dotgit .. "/HEAD"
  end
  local fd = io.open(dotgit, "r")
  if not fd then return nil end
  local line = fd:read("*l") or ""
  fd:close()
  local gitdir = line:match("^gitdir:%s*(.+)$")
  if not gitdir then return nil end
  if not gitdir:match("^/") then gitdir = dir .. "/" .. gitdir end
  return gitdir .. "/HEAD"
end

-- Branch name from a HEAD file: the ref short name, or a short SHA when detached.
local function parse_head(headpath)
  local fd = io.open(headpath, "r")
  if not fd then return nil end
  local content = fd:read("*l") or ""
  fd:close()
  local branch = content:match("^ref:%s*refs/heads/(.+)$")
  if branch then return branch end
  local sha = content:match("^(%x+)$")        -- detached HEAD
  if sha then return sha:sub(1, 7) end
  return nil
end

-- Branch for the repo rooted at `dir`, or nil if `dir` isn't a work-tree root.
function M.branch_of(dir)
  local headpath = head_file(dir)
  if not headpath then
    cache[dir] = nil
    return nil
  end
  local hstat = uv.fs_stat(headpath)
  local mtime = hstat and hstat.mtime and hstat.mtime.sec or 0
  local c = cache[dir]
  if c and c.headpath == headpath and c.mtime == mtime then
    return c.branch
  end
  local branch = parse_head(headpath)
  cache[dir] = { mtime = mtime, headpath = headpath, branch = branch }
  return branch
end

-- Build the nvim-tree Decorator class. Must be called after nvim-tree loaded.
function M.decorator()
  local Decorator = require("nvim-tree.api").Decorator
  local GitBranch = Decorator:extend()

  function GitBranch:new()
    self.enabled = true
    self.highlight_range = "none"
    self.icon_placement = "after"
  end

  function GitBranch:icons(node)
    if node.type ~= "directory" then return nil end
    local branch = M.branch_of(node.absolute_path)
    if not branch then return nil end
    return { { str = " " .. branch, hl = { "NvimTreeGitBranch" } } }
  end

  return GitBranch
end

return M
