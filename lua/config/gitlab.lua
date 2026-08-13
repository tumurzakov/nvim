-- gitlab: minimal read-only GitLab API helper for :ReviewMR — fetches a merge
-- request's metadata (title, source branch) so the review can label itself with
-- the real branch and derive the Jira ticket key.
--
-- Token is resolved (and cached per-root) from, in order:
--   1) settings_local.gitlab = { token = "..." }
--   2) $GITLAB_TOKEN
--   3) GITLAB_TOKEN in a .env at <root>, <root>/.., or <root>/../.. (where the
--      nbs-art clones keep it)
local M = {}

-- Read KEY=value from a .env file; returns the value for `key` or nil.
local function env_value(path, key)
  if vim.fn.filereadable(path) ~= 1 then return nil end
  for _, line in ipairs(vim.fn.readfile(path)) do
    local v = line:match("^%s*" .. key .. "%s*=%s*(.+)%s*$")
    if v then
      v = v:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
      if v ~= "" then return v end
    end
  end
  return nil
end

local function resolve_token(root)
  local j = require("config.settings").get("gitlab")
  j = type(j) == "table" and j or {}
  if j.token and j.token ~= "" then return j.token end
  local env = os.getenv("GITLAB_TOKEN")
  if env and env ~= "" then return env end
  local dir = root
  for _ = 1, 3 do
    local t = env_value(dir .. "/.env", "GITLAB_TOKEN")
    if t then return t end
    dir = vim.fn.fnamemodify(dir, ":h")
  end
  return nil
end

-- host + "group/sub/project" from a repo's origin URL (https or ssh form).
local function host_project(root)
  local out = vim.fn.systemlist({ "git", "-C", root, "remote", "get-url", "origin" })
  if vim.v.shell_error ~= 0 or not out[1] then return nil end
  local url = out[1]
  local host, proj = url:match("^https?://[^/]-@?([^/]+)/(.+)$")   -- https://host/group/proj(.git)
  if not host then host, proj = url:match("^[^@]+@([^:]+):(.+)$") end -- git@host:group/proj(.git)
  if not host or not proj then return nil end
  return host, (proj:gsub("%.git$", ""))
end

-- Fetch MR `iid` for the repo at `root`. cb(mr|nil, err) where mr =
-- { title, source_branch, target_branch, author }. Best-effort: cb(nil, reason)
-- if no token / no origin / API error, so callers can fall back gracefully.
function M.mr_for_repo(root, iid, cb)
  local token = resolve_token(root)
  if not token then cb(nil, "no GitLab token"); return end
  local host, project = host_project(root)
  if not host then cb(nil, "no origin remote"); return end
  local url = ("https://%s/api/v4/projects/%s/merge_requests/%d"):format(
    host, vim.uri_encode(project, "rfc2396"), iid)
  vim.system(
    { "curl", "-sS", "--max-time", "8", "-H", "PRIVATE-TOKEN: " .. token, url },
    { text = true },
    vim.schedule_wrap(function(res)
      if res.code ~= 0 then cb(nil, vim.trim(res.stderr or "curl failed")); return end
      local ok, d = pcall(vim.json.decode, res.stdout or "")
      if not ok or type(d) ~= "table" or not d.iid then
        cb(nil, (type(d) == "table" and d.message) or "MR not found"); return
      end
      cb({
        title = d.title or "",
        source_branch = d.source_branch or "",
        target_branch = d.target_branch or "",
        author = (d.author or {}).name or "",
      })
    end)
  )
end

return M
