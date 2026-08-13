-- Python project runners (pytest / ruff / run-current-file), preferring Poetry
-- when the project has a pyproject.toml. Commands execute in the run terminal.
local M = {}

local vu = require("config.vim_util")
local rt = require("config.run_terminal")

local function project_root_for_path(path)
  local start = path ~= "" and vim.fs.dirname(vim.fs.normalize(path)) or vim.fn.getcwd()
  local marker = vim.fs.find({ "pyproject.toml", "pytest.ini", "tox.ini", "setup.cfg", ".git" }, {
    path = start,
    upward = true,
  })[1]
  if marker then
    return vim.fs.dirname(marker)
  end
  return vim.fn.getcwd()
end

local function has_pyproject(path_for_root)
  local root = project_root_for_path(path_for_root or "")
  local pyproject = vim.fs.find("pyproject.toml", { path = root, upward = false })[1]
  return pyproject ~= nil
end

local function poetry_prefix(path_for_root)
  if vim.fn.executable("poetry") == 1 and has_pyproject(path_for_root) then
    return "poetry run "
  end
  return ""
end

local function join_command(cmd, args)
  if args == nil or args == "" then
    return cmd
  end
  return cmd .. " " .. args
end

local function build_python_command(args, path_for_root)
  local prefix = poetry_prefix(path_for_root)
  if prefix ~= "" then
    return join_command(prefix .. "python", args)
  end

  local python_bin = vim.fn.executable("python3") == 1 and "python3" or "python"
  return join_command(python_bin, args)
end

local function build_pytest_command(args, path_for_root)
  return join_command(poetry_prefix(path_for_root) .. "pytest", args)
end

local function build_ruff_command(args, path_for_root)
  return join_command(poetry_prefix(path_for_root) .. "ruff", args)
end

local function run_in_project(command, path_for_root)
  rt.run_command(command, project_root_for_path(path_for_root or ""))
end

-- The pytest node id (file::Class::test_fn) nearest above the cursor, or nil.
local function nearest_pytest_nodeid()
  local file = vim.fn.expand("%:p")
  if file == "" then
    return nil
  end

  local row = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(0, 0, row, false)
  local test_name
  local test_indent = -1
  local class_name

  for i = #lines, 1, -1 do
    local line = lines[i]

    if not test_name then
      local indent, fn = line:match("^(%s*)def%s+(test[%w_]+)%s*%(")
      if not fn then
        indent, fn = line:match("^(%s*)async%s+def%s+(test[%w_]+)%s*%(")
      end
      if fn then
        test_name = fn
        test_indent = #indent
      end
    else
      local cls_indent, cls = line:match("^(%s*)class%s+(Test[%w_]*)%s*[%(:]")
      if cls and #cls_indent < test_indent then
        class_name = cls
        break
      end
    end
  end

  if not test_name then
    return nil
  end

  if class_name then
    return string.format("%s::%s::%s", file, class_name, test_name)
  end

  return string.format("%s::%s", file, test_name)
end

function M.pytest_all()
  local file = vim.fn.expand("%:p")
  run_in_project(build_pytest_command("", file), file)
end

function M.pytest_file()
  local file = vim.fn.expand("%:p")
  if file == "" then
    print("No file in current buffer")
    return
  end
  run_in_project(build_pytest_command(vim.fn.shellescape(file), file), file)
end

function M.pytest_nearest()
  local mode = vim.fn.mode()
  if mode:match("[vV\22]") then
    local start_pos = vim.api.nvim_buf_get_mark(0, "<")
    if start_pos[1] > 0 then
      vim.api.nvim_win_set_cursor(0, { start_pos[1], start_pos[2] })
    end
    vu.leave_visual_mode()
  end

  local nodeid = nearest_pytest_nodeid()
  local file = vim.fn.expand("%:p")
  if not nodeid then
    print("Could not find nearest test_* function")
    return
  end

  run_in_project(build_pytest_command(vim.fn.shellescape(nodeid), file), file)
end

function M.ruff_fix_current_file()
  local file = vim.fn.expand("%:p")
  if file == "" then
    print("No file in current buffer")
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].modified then
    vim.cmd("write")
  end

  run_in_project(build_ruff_command("check --fix " .. vim.fn.shellescape(file), file), file)

  -- Ruff runs asynchronously in the terminal; re-check the file after it has
  -- likely completed (twice, since run time varies).
  local function checktime_later(delay)
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == file and not vim.bo[bufnr].modified then
        vim.cmd("checktime " .. bufnr)
      end
    end, delay)
  end
  checktime_later(1200)
  checktime_later(2500)
end

function M.run_current_script()
  local file = vim.fn.expand("%:p")
  if file == "" then
    print("No file in current buffer")
    return
  end

  if vim.bo.filetype ~= "python" and not file:match("%.py$") then
    print("Current buffer is not a Python file")
    return
  end

  if vim.bo.modified then
    vim.cmd("write")
  end

  run_in_project(build_python_command(vim.fn.shellescape(file), file), file)
end

return M
