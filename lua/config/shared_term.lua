local M = {}

---@class SharedTerm
---@field bufnr integer
---@field cwd string

---@type SharedTerm[]  -- MRU order: index 1 is most recently used
local terminals = {}

local function job_alive(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return false end
  local ok, chan = pcall(vim.api.nvim_buf_get_var, bufnr, "terminal_job_id")
  if not ok or not chan then return false end
  return vim.fn.jobwait({ chan }, 0)[1] == -1
end

local function gc()
  local alive = {}
  for _, t in ipairs(terminals) do
    if job_alive(t.bufnr) then table.insert(alive, t) end
  end
  terminals = alive
end

local function normalize_path(p)
  if not p or p == "" then return p end
  local abs = vim.fn.fnamemodify(p, ":p")
  if #abs > 1 and abs:sub(-1) == "/" then
    abs = abs:sub(1, -2)
  end
  return abs
end

local function find_window_for(bufnr)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
  return nil
end

local function find_terminal_for_path(path)
  for _, t in ipairs(terminals) do
    if t.cwd == path then return t end
  end
  return nil
end

local function any_visible_terminal()
  for _, t in ipairs(terminals) do
    local win = find_window_for(t.bufnr)
    if win then return t, win end
  end
  return nil
end

local function find_main_editor_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local bt = vim.bo[buf].buftype
    local ft = vim.bo[buf].filetype
    if bt == "" and ft ~= "NvimTree" and ft ~= "aerial" then
      return win
    end
  end
  return nil
end

local function open_split(layout)
  if layout == "vsplit" then
    vim.cmd("botright vsplit")
  else
    local height = math.max(3, math.floor(vim.o.lines * 0.15))
    vim.cmd("botright " .. tostring(height) .. "split")
  end
  return vim.api.nvim_get_current_win()
end

local function attach_existing(t, layout)
  local win = open_split(layout)
  vim.api.nvim_win_set_buf(win, t.bufnr)
  return win
end

local function create_new(path, layout)
  local win = open_split(layout)
  -- lcd makes :terminal spawn the shell in `path` directly (no startup `cd` flicker).
  vim.cmd("lcd " .. vim.fn.fnameescape(path))
  vim.cmd("terminal")
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].bufhidden = "hide"
  local t = { bufnr = bufnr, cwd = path }
  table.insert(terminals, 1, t)
  return t, win
end

local function move_to_mru(t)
  for i, x in ipairs(terminals) do
    if x == t then
      table.remove(terminals, i)
      table.insert(terminals, 1, t)
      return
    end
  end
end

---Does a live terminal already exist for this folder? Accepts a file or dir
---path; files resolve to their parent directory (matching M.cd).
---@param path string
---@return boolean
function M.has(path)
  if not path or path == "" then return false end
  if vim.fn.isdirectory(path) == 0 then path = vim.fs.dirname(path) end
  path = normalize_path(path)
  gc()
  return find_terminal_for_path(path) ~= nil
end

---Switch to (or create) a terminal at the given path.
---If `path` is a file, uses its parent directory.
---Prefers to reuse: (1) the visible terminal window, (2) the main editor
---window. Falls back to a new split. Stays in normal mode.
---By default returns focus to the calling window; pass `opts.focus = true`
---to leave focus on the terminal.
---@param path string
---@param opts? { layout?: "split"|"vsplit", focus?: boolean }
function M.cd(path, opts)
  if not path or path == "" then return end
  opts = opts or {}
  local layout = opts.layout or "vsplit"
  if vim.fn.isdirectory(path) == 0 then
    path = vim.fs.dirname(path)
  end
  path = normalize_path(path)
  gc()

  local origin = vim.api.nvim_get_current_win()
  local target = find_terminal_for_path(path)
  local _, term_win = any_visible_terminal()
  local host_win = term_win or find_main_editor_win()
  local landed_win

  if target then
    if host_win then
      vim.api.nvim_win_set_buf(host_win, target.bufnr)
      landed_win = host_win
    else
      landed_win = attach_existing(target, layout)
    end
    move_to_mru(target)
  elseif host_win then
    vim.api.nvim_set_current_win(host_win)
    vim.cmd("lcd " .. vim.fn.fnameescape(path))
    vim.cmd("terminal")
    local bufnr = vim.api.nvim_get_current_buf()
    vim.bo[bufnr].bufhidden = "hide"
    table.insert(terminals, 1, { bufnr = bufnr, cwd = path })
    landed_win = host_win
  else
    local _, win = create_new(path, layout)
    landed_win = win
  end

  if opts.focus then
    if landed_win and vim.api.nvim_win_is_valid(landed_win) then
      vim.api.nvim_set_current_win(landed_win)
    end
  else
    if origin and vim.api.nvim_win_is_valid(origin) then
      vim.api.nvim_set_current_win(origin)
    end
  end
end

return M
