-- jira: fetch a single issue from EPAM Jira (Data Center REST v2) for the review
-- view. Thin read-only wrapper — same endpoint/auth as the epam-jira MCP server:
--   GET <base>/rest/api/2/issue/<KEY>   with  Authorization: Bearer <token>
--
-- Token/base are resolved (and cached) from, in order:
--   1) settings_local.jira = { base_url = "...", token = "..." }
--   2) $JIRA_API_TOKEN / $JIRA_BASE_URL
--   3) the epam-jira server's env in ~/.claude.json (where it already lives)
local M = {}

local DEFAULT_BASE = "https://jiraeu.epam.com"
local _token, _base, _resolved

-- JSON null decodes to vim.NIL (userdata), which is truthy — so `x or ""` won't
-- fall through and vim.trim/format later blow up. Coerce anything not a string.
local function str(v)
  return type(v) == "string" and v or ""
end

-- Same trap for nested objects: `(f.assignee or {}).name` keeps vim.NIL (a
-- truthy userdata) when the field is JSON null, then indexing it throws. Coerce
-- anything that isn't a real table to {} before drilling in.
local function tbl(v)
  return type(v) == "table" and v or {}
end

-- Recursively find the first key `k` anywhere in a decoded-JSON table.
local function deep_find(tbl, k)
  if type(tbl) ~= "table" then return nil end
  if tbl[k] ~= nil and type(tbl[k]) == "string" then return tbl[k] end
  for _, v in pairs(tbl) do
    local r = deep_find(v, k)
    if r then return r end
  end
  return nil
end

local function from_claude_json(key)
  local path = vim.fn.expand("~/.claude.json")
  if vim.fn.filereadable(path) ~= 1 then return nil end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  end)
  if not ok then return nil end
  return deep_find(data, key)
end

local function resolve()
  if _resolved then return end
  _resolved = true
  local j = require("config.settings").get("jira")
  j = type(j) == "table" and j or {}
  _token = j.token or os.getenv("JIRA_API_TOKEN") or from_claude_json("JIRA_API_TOKEN")
  _base = (j.base_url or os.getenv("JIRA_BASE_URL") or from_claude_json("JIRA_BASE_URL") or DEFAULT_BASE)
    :gsub("/$", "")
end

-- Master trigger. The whole ticket integration (auto-fetch, sidebar node, gJ, and
-- the :ReviewMR GitLab lookup) stays OFF unless settings_local.jira.enabled == true.
-- Default off so environments without Jira (e.g. Novartis) make no external calls.
function M.enabled()
  local j = require("config.settings").get("jira")
  return type(j) == "table" and j.enabled == true
end

function M.configured()
  resolve()
  return _token ~= nil and _token ~= ""
end

function M.base_url()
  resolve()
  return _base
end

-- Fetch issue `key` asynchronously. cb(issue|nil, err) where issue =
-- { key, summary, type, status, priority, assignee, labels, description, url }.
function M.fetch(key, cb)
  resolve()
  if not M.configured() then cb(nil, "no Jira token configured"); return end
  local fields = "summary,description,issuetype,status,assignee,priority,labels,parent"
  local url = ("%s/rest/api/2/issue/%s?fields=%s"):format(_base, key, fields)
  vim.system(
    { "curl", "-sS", "-H", "Authorization: Bearer " .. _token, url },
    { text = true },
    vim.schedule_wrap(function(res)
      if res.code ~= 0 then cb(nil, vim.trim(res.stderr or "curl failed")); return end
      local ok, d = pcall(vim.json.decode, res.stdout or "")
      if not ok or type(d) ~= "table" then cb(nil, "bad JSON from Jira"); return end
      if not d.key then
        local msg = d.errorMessages and table.concat(d.errorMessages, "; ") or "issue not found"
        cb(nil, msg); return
      end
      local f = tbl(d.fields)
      local assignee = str(tbl(f.assignee).displayName)
      cb({
        key = d.key,
        summary = str(f.summary),
        type = str(tbl(f.issuetype).name),
        status = str(tbl(f.status).name),
        priority = str(tbl(f.priority).name),
        assignee = assignee ~= "" and assignee or "unassigned",
        labels = type(f.labels) == "table" and f.labels or {},
        description = str(f.description),
        url = _base .. "/browse/" .. d.key,
      })
    end)
  )
end

-- Render an issue as markdown lines. First line is a marker so the review view
-- can tell its own mirror apart from a hand-authored ticket.md and never clobber.
function M.render_md(issue)
  local out = { "<!-- auto-generated from Jira; edits will be overwritten -->" }
  table.insert(out, ("# [%s] %s"):format(issue.key, issue.summary))
  table.insert(out, "")
  table.insert(out, ("**Type:** %s  **Status:** %s  **Priority:** %s"):format(
    issue.type, issue.status, issue.priority))
  table.insert(out, ("**Assignee:** %s"):format(issue.assignee))
  if #issue.labels > 0 then table.insert(out, ("**Labels:** %s"):format(table.concat(issue.labels, ", "))) end
  table.insert(out, ("**URL:** %s"):format(issue.url))
  table.insert(out, "")
  table.insert(out, "## Description")
  table.insert(out, "")
  local desc = vim.trim(issue.description or "")
  if desc == "" then
    table.insert(out, "_(no description)_")
  else
    for _, l in ipairs(vim.split(desc:gsub("\r\n", "\n"), "\n", { plain = true })) do
      table.insert(out, l)
    end
  end
  return out
end

return M
