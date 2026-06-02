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

-- Diffview RevType enum: LOCAL=1, COMMIT=2, STAGE=3, CUSTOM=4
local function rev_display(rev)
  if not rev then return nil end
  if rev.type == 1 then return "working tree" end
  if rev.type == 3 then return "staged" end
  if rev.commit then return rev.commit:sub(1, 12) end
  return nil
end

local function rev_ref(rev)
  if not rev then return nil end
  if rev.commit then return rev.commit end
  -- LOCAL/STAGE have no commit; let the caller handle this case.
  return nil
end

local function current_file_path(view)
  -- DiffView
  if view.panel and view.panel.cur_file and view.panel.cur_file.path then
    return view.panel.cur_file.path
  end
  -- FileHistoryView: panel.cur_item is {LogEntry, FileEntry}
  if view.panel and view.panel.cur_item then
    local cur = view.panel.cur_item
    if type(cur) == "table" and cur[2] and cur[2].path then
      return cur[2].path
    end
  end
  return nil
end

local function file_history_revs(view)
  -- For FileHistoryView, derive left/right from the current log entry.
  if not (view.panel and view.panel.cur_item) then return nil, nil end
  local cur = view.panel.cur_item
  local log_entry = type(cur) == "table" and cur[1] or nil
  if not log_entry or not log_entry.commit then return nil, nil end
  return log_entry.commit.parent_hash or (log_entry.commit.hash .. "^"),
    log_entry.commit.hash
end

---Return the active Diffview view's file/rev info, or nil.
function M.diffview()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then return nil end
  local view = lib.get_current_view()
  if not view then return nil end

  local adapter = view.adapter
  local root = (adapter and adapter.ctx and adapter.ctx.toplevel) or repo_root(current_file_path(view))
  if not root then return nil end

  local file = current_file_path(view)
  local left_sha = rev_ref(view.left)
  local right_sha = rev_ref(view.right)
  local left_display = rev_display(view.left)
  local right_display = rev_display(view.right)

  -- FileHistoryView path: no view.left/right; derive from current commit.
  if not left_sha and not right_sha then
    local l, r = file_history_revs(view)
    left_sha, right_sha = l, r
    left_display = left_display or (l and l:sub(1, 12))
    right_display = right_display or (r and r:sub(1, 12))
  end

  -- Prefer rev_arg (user-supplied range like "develop..origin/feature/...") for display.
  local rev_arg = view.rev_arg
  if rev_arg and rev_arg ~= "" then
    local l, r = rev_arg:match("^(.-)%.%.%.?(.+)$")
    if l and r then
      left_display = l
      right_display = r
      left_sha = left_sha or l
      right_sha = right_sha or r
    elseif left_sha and not right_sha then
      -- single-ref rev_arg (e.g. "origin/feature/...") — branch tip
      right_display = rev_arg
      right_sha = right_sha or rev_arg
    end
  end

  local right_is_local = view.right and (view.right.type == 1 or view.right.type == 3)

  return {
    file = file,
    left_sha = left_sha,
    right_sha = right_sha,
    right_is_local = right_is_local,
    left_display = left_display or "?",
    right_display = right_display or (right_is_local and "working tree" or "?"),
    root = root,
  }
end


---Fallback when no Diffview view is active: use base branch vs HEAD for the current buffer.
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
