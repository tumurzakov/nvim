-- Shared accessor for config.settings_local (git-ignored, may be absent).
-- Replaces the pcall(require)+type-check idiom that was copy-pasted per call site.
local M = {}

-- The settings_local table, or {} when the file is missing/broken.
function M.raw()
  local ok, sl = pcall(require, "config.settings_local")
  if ok and type(sl) == "table" then return sl end
  return {}
end

-- settings_local[key], or `default` when unset.
function M.get(key, default)
  local v = M.raw()[key]
  if v == nil then return default end
  return v
end

-- The remote to fetch/push against (settings_local.git_remote).
function M.remote()
  return M.get("git_remote", "origin")
end

-- The configured base branch. Callers pass their own default because sites
-- intentionally differ (e.g. MR review defaults to "develop", others to "main").
function M.base_branch(default)
  return M.get("git_base_branch", default or "main")
end

return M
