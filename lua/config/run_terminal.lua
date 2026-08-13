-- The "run" terminal: a right-split scratch terminal for firing off selections,
-- lines and project commands (<leader>r / <leader>rl / the Python runners).
-- Distinct from config.shared_term (repo terminals) and config.term_switcher.
local M = {}

local vu = require("config.vim_util")

local function job_running(job_id)
  if not job_id then
    return false
  end
  return vim.fn.jobwait({ job_id }, 0)[1] == -1
end

local function buf_terminal_channel(buf)
  if vim.bo[buf].buftype ~= "terminal" then
    return nil
  end
  local ok, chan = pcall(vim.api.nvim_buf_get_var, buf, "terminal_job_id")
  if ok and job_running(chan) then
    return chan
  end
  return nil
end

-- Dedicated "run" terminal marker. It is tagged with a buffer-local flag so it
-- is never confused with a \T repo terminal or a `C-b c` terminal tab — running
-- a selection must NEVER silently hijack an unrelated shell.
local RUN_TERM_VAR = "run_scratch_terminal"

local function buf_is_run_terminal(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  if vim.bo[buf].buftype ~= "terminal" then
    return false
  end
  local ok, v = pcall(vim.api.nvim_buf_get_var, buf, RUN_TERM_VAR)
  return ok and v == true
end

-- Locate a live run-terminal. Returns chan, buf, win (win is nil if hidden).
local function find_run_terminal()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if buf_is_run_terminal(buf) then
      local chan = buf_terminal_channel(buf)
      if chan then
        return chan, buf, win
      end
    end
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and buf_is_run_terminal(buf) then
      local chan = buf_terminal_channel(buf)
      if chan then
        return chan, buf, nil
      end
    end
  end

  return nil
end

-- Open a fresh terminal in a right split, wait for its channel, return to the
-- origin window. `tag` marks it as the dedicated run-terminal.
local function open_split_terminal(tag)
  local origin = vim.api.nvim_get_current_win()
  vim.cmd("botright vsplit")
  vim.cmd("terminal")

  local bufnr = vim.api.nvim_get_current_buf()
  if tag then
    pcall(vim.api.nvim_buf_set_var, bufnr, RUN_TERM_VAR, true)
  end

  local chan
  for _ = 1, 30 do
    local ok, c = pcall(vim.api.nvim_buf_get_var, bufnr, "terminal_job_id")
    if ok and c and job_running(c) then
      chan = c
      break
    end
    vim.wait(20)
  end

  if vim.api.nvim_win_is_valid(origin) then
    vim.api.nvim_set_current_win(origin)
  end
  return chan
end

local function ensure_run_terminal_channel()
  local origin = vim.api.nvim_get_current_win()
  local chan, buf, win = find_run_terminal()

  if chan then
    -- Reuse our own run-terminal. If it is hidden, surface it in a right split
    -- so output is always visible (fixes the original silent-execution issue).
    if not win then
      vim.cmd("botright vsplit")
      vim.api.nvim_win_set_buf(0, buf)
      if vim.api.nvim_win_is_valid(origin) then
        vim.api.nvim_set_current_win(origin)
      end
    end
    return chan
  end

  return open_split_terminal(true)
end

-- Any visible terminal in the current tab (for project commands, which are
-- happy to reuse whatever terminal is already on screen).
local function ensure_visible_terminal_channel()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local chan = buf_terminal_channel(vim.api.nvim_win_get_buf(win))
    if chan then
      return chan
    end
  end
  return open_split_terminal(false)
end

local function scroll_terminal_to_bottom(chan)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == "terminal" then
      local ok, job_id = pcall(vim.api.nvim_buf_get_var, buf, "terminal_job_id")
      if ok and job_id == chan then
        local line_count = vim.api.nvim_buf_line_count(buf)
        pcall(vim.api.nvim_win_set_cursor, win, { line_count, 0 })
        break
      end
    end
  end
end

local function chansend_line(chan, payload)
  if not payload:match("\n$") then
    payload = payload .. "\n"
  end
  vim.fn.chansend(chan, payload)
  vim.schedule(function() scroll_terminal_to_bottom(chan) end)
end

-- Send `text` to the dedicated run-terminal (opening it if needed).
function M.send(text)
  local chan = ensure_run_terminal_channel()
  if not chan then
    print("Could not open terminal")
    return false
  end
  chansend_line(chan, text)
  return true
end

function M.run_selection()
  local text = vu.visual_text()
  if text == "" then
    vu.leave_visual_mode()
    return
  end
  M.send(text)
  vu.leave_visual_mode()
end

function M.run_line()
  local line = vim.trim(vim.api.nvim_get_current_line())
  if line == "" then
    print("Empty line")
    return
  end
  M.send(line)
end

-- Run `command` from `root` in a visible terminal (reusing one, else opening a
-- right split). Used by the Python runners.
function M.run_command(command, root)
  local full = string.format("cd %s && %s", vim.fn.shellescape(root), command)
  local chan = ensure_visible_terminal_channel()
  if not chan then
    print("Could not open terminal")
    return
  end
  chansend_line(chan, full)
end

-- Terminal TAB navigation (C-b n/p/c): move between tabs, landing in a
-- terminal window in insert mode when the tab has one.
function M.tab_next(direction)
  if direction == 1 then
    vim.cmd("tabnext")
  else
    vim.cmd("tabprevious")
  end

  if vim.bo.buftype == "terminal" then
    vim.cmd("startinsert")
    return
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == "terminal" then
      vim.api.nvim_set_current_win(win)
      vim.cmd("startinsert")
      return
    end
  end
end

function M.new_tab()
  vim.cmd("tabnew")
  vim.cmd("terminal")
  vim.cmd("startinsert")
end

return M
