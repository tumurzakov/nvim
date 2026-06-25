-- Floating terminal picker. Lists all live terminals (folder + kind), and on
-- selection shows the chosen terminal in the rightmost editor window — never
-- splitting, tabbing, or opening a new window, and never touching nvim-tree.
local M = {}

local RUN_TERM_VAR = "run_scratch_terminal"

local function job_alive(buf)
  local ok, chan = pcall(vim.api.nvim_buf_get_var, buf, "terminal_job_id")
  if not ok or not chan then return false end
  return vim.fn.jobwait({ chan }, 0)[1] == -1
end

local function is_live_terminal(buf)
  return vim.api.nvim_buf_is_valid(buf)
    and vim.api.nvim_buf_is_loaded(buf)
    and vim.bo[buf].buftype == "terminal"
    and job_alive(buf)
end

-- Parse the cwd + command out of a `term://<cwd>//<pid>:<cmd>` buffer name.
local function term_info(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local cwd, _, cmd = name:match("^term://(.-)//(%d+):(.*)$")
  local folder = cwd and vim.fn.fnamemodify(cwd, ":~") or "?"
  local first = cmd and (vim.split(cmd, " ", { plain = true })[1] or cmd) or ""
  local shortcmd = first ~= "" and vim.fn.fnamemodify(first, ":t") or "term"

  local kind = ""
  local okv, v = pcall(vim.api.nvim_buf_get_var, buf, RUN_TERM_VAR)
  if okv and v == true then
    kind = "[run]"
  else
    local ok_st, st = pcall(require, "config.shared_term")
    if ok_st and st.is_shared and st.is_shared(buf) then
      kind = "[\\T]"
    end
  end

  return { buf = buf, folder = folder, cmd = shortcmd, kind = kind }
end

local function list_terminals()
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if is_live_terminal(buf) then
      out[#out + 1] = term_info(buf)
    end
  end
  table.sort(out, function(a, b) return a.buf < b.buf end)
  return out
end

-- Rightmost non-floating window that is not nvim-tree / aerial.
local function rightmost_target_win()
  local best, best_col = nil, -1
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local cfg = vim.api.nvim_win_get_config(w)
    if cfg.relative == "" then
      local ft = vim.bo[vim.api.nvim_win_get_buf(w)].filetype
      if ft ~= "NvimTree" and ft ~= "aerial" then
        local col = vim.api.nvim_win_get_position(w)[2]
        if col > best_col then
          best_col = col
          best = w
        end
      end
    end
  end
  return best
end

local function open_in_right(buf)
  local target = rightmost_target_win()
  if not target then
    vim.notify("No editor window to show the terminal in", vim.log.levels.WARN)
    return
  end
  vim.api.nvim_win_set_buf(target, buf)
  vim.api.nvim_set_current_win(target)
  vim.cmd("startinsert")
end

function M.pick()
  local terms = list_terminals()
  if #terms == 0 then
    vim.notify("No terminals open", vim.log.levels.INFO)
    return
  end

  local lines = {}
  for i, t in ipairs(terms) do
    local tag = t.kind ~= "" and ("  " .. t.kind) or ""
    lines[i] = string.format(" %d. %s   (%s)%s", i, t.folder, t.cmd, tag)
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false

  local title = " Terminals  (1-9 · Enter · q) "
  local width = vim.fn.strdisplaywidth(title)
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 4)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })
  vim.wo[win].cursorline = true

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function choose(idx)
    local t = terms[idx]
    if not t then return end
    close()
    if vim.api.nvim_buf_is_valid(t.buf) then
      open_in_right(t.buf)
    end
  end

  local function map(lhs, rhs)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true })
  end
  map("q", close)
  map("<Esc>", close)
  map("<CR>", function() choose(vim.api.nvim_win_get_cursor(win)[1]) end)
  for i = 1, math.min(#terms, 9) do
    map(tostring(i), function() choose(i) end)
  end
end

return M
