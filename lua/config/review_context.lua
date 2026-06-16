local M = {}

local function repo_root(path)
  local start = (path and path ~= "") and vim.fs.dirname(path) or vim.fn.getcwd()
  local git_dir = vim.fs.find(".git", { path = start, upward = true })[1]
  return git_dir and vim.fs.dirname(git_dir) or nil
end

local function settings_base_branch()
  local ok, settings = pcall(require, "config.settings_local")
  return (ok and settings.git_base_branch) or "main"
end

local function shell(args, cwd)
  local res = vim.system(args, { text = true, cwd = cwd }):wait()
  return res.code == 0, (res.stdout or "") .. (res.stderr or "")
end

---Review context for the current buffer: base branch vs HEAD.
function M.fallback()
  local buf_path = vim.api.nvim_buf_get_name(0)
  local root = repo_root(buf_path)
  if not root then return nil end
  local base = settings_base_branch()
  return {
    file = buf_path ~= "" and vim.fn.fnamemodify(buf_path, ":.") or nil,
    left_sha = base,
    right_sha = "HEAD",
    left_display = base,
    right_display = "HEAD",
    root = root,
  }
end

function M.repo_name(root)
  return root and vim.fn.fnamemodify(root, ":t") or "?"
end

---@param opts? { right_is_local?: boolean }
function M.diff(root, left, right, file, opts)
  if not root or not left then return nil end
  opts = opts or {}
  local args = { "git", "-C", root, "diff" }
  if opts.right_is_local then
    -- Working tree or index vs left
    table.insert(args, left)
  else
    if not right then return nil end
    table.insert(args, left .. ".." .. right)
  end
  if file then
    table.insert(args, "--")
    table.insert(args, file)
  end
  local ok, out = shell(args, root)
  if not ok then return nil, "git diff failed: " .. out end
  return vim.trim(out)
end

function M.commit_subjects(root, left, right, limit)
  if not root or not left or not right then return {} end
  local args = { "git", "-C", root, "log", "--format=%s" }
  if limit then table.insert(args, "-n" .. limit) end
  table.insert(args, left .. ".." .. right)
  local ok, out = shell(args, root)
  if not ok then return {} end
  local subjects = {}
  for line in (out or ""):gmatch("[^\n]+") do
    table.insert(subjects, line)
  end
  return subjects
end

---Format a list of commit subjects for inclusion in a prompt.
function M.format_subjects(subjects, max_shown)
  max_shown = max_shown or 20
  if not subjects or #subjects == 0 then return nil end
  local lines = {}
  for i = 1, math.min(#subjects, max_shown) do
    table.insert(lines, "- " .. subjects[i])
  end
  if #subjects > max_shown then
    table.insert(lines, string.format("- … and %d more", #subjects - max_shown))
  end
  return table.concat(lines, "\n")
end

return M
