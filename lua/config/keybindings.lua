local default_opts = { noremap = true, silent = true }
local cc_k = require("config.codecompanion_k")

local function map(mode, lhs, rhs, opts)
  vim.keymap.set(mode, lhs, rhs, vim.tbl_extend("force", default_opts, opts or {}))
end

local function feedkeys(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "n", false)
end

local function leave_visual_mode()
  feedkeys("<Esc>")
end

local function leave_terminal_mode()
  feedkeys("<C-\\><C-n>")
end

local function get_visual_selection_from_marks()
  local bufnr = 0
  local start_pos = vim.api.nvim_buf_get_mark(bufnr, "<")
  local end_pos = vim.api.nvim_buf_get_mark(bufnr, ">")

  if start_pos[1] == 0 or end_pos[1] == 0 then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, start_pos[1] - 1, end_pos[1], false)
  if vim.tbl_isempty(lines) then
    return nil
  end

  lines[#lines] = string.sub(lines[#lines], 1, end_pos[2] + 1)
  lines[1] = string.sub(lines[1], start_pos[2] + 1)
  return table.concat(lines, "\n")
end

local function open_codecompanion_chat_with_selection()
  local mode = vim.fn.mode()
  local has_selection = mode:match("[vV\22]") ~= nil
  local selection = has_selection and get_visual_selection_from_marks() or nil

  if has_selection then
    leave_visual_mode()
  end

  local cc = require("codecompanion")
  local chat = cc.chat({
    messages = selection and { { role = "user", content = selection } } or nil,
    auto_submit = false,
  })

  vim.schedule(function()
    if chat and chat.ui and chat.ui.win and vim.api.nvim_win_is_valid(chat.ui.win) then
      vim.api.nvim_set_current_win(chat.ui.win)
    end
    vim.cmd("startinsert")
  end)
end

local function open_diagnostics_float()
  vim.diagnostic.open_float(nil, {
    focusable = false,
    close_events = { "BufLeave", "CursorMoved", "InsertEnter", "FocusLost" },
    border = "rounded",
    source = "always",
    prefix = " ",
    scope = "cursor",
  })
end

local function tab_terminal_next(direction)
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

local function open_new_terminal_tab()
  vim.cmd("tabnew")
  vim.cmd("terminal")
  vim.cmd("startinsert")
end

local function open_terminal_vsplit_and_return_focus()
  local origin_win = vim.api.nvim_get_current_win()
  vim.cmd("botright vsplit")
  vim.cmd("terminal")
  if origin_win and vim.api.nvim_win_is_valid(origin_win) then
    vim.api.nvim_set_current_win(origin_win)
  end
end

local function toggle_terminal_vsplit_and_return_focus()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == "terminal" then
      vim.api.nvim_win_close(win, true)
      return
    end
  end
  open_terminal_vsplit_and_return_focus()
end

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

local function find_terminal_channel()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local chan = buf_terminal_channel(vim.api.nvim_win_get_buf(win))
    if chan then
      return chan
    end
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local chan = buf_terminal_channel(buf)
    if chan then
      return chan
    end
  end

  return nil
end

local function ensure_terminal_channel()
  local chan = find_terminal_channel()
  if chan then
    return chan
  end

  vim.cmd("tabnew")
  vim.cmd("terminal")

  local bufnr = vim.api.nvim_get_current_buf()
  for _ = 1, 30 do
    local ok, new_chan = pcall(vim.api.nvim_buf_get_var, bufnr, "terminal_job_id")
    if ok and new_chan and job_running(new_chan) then
      return new_chan
    end
    vim.wait(20)
  end

  return nil
end

local function get_visual_text()
  local reg_z = vim.fn.getreginfo("z")
  vim.cmd('silent normal! "zy')
  local text = vim.fn.getreg("z")
  vim.fn.setreg("z", reg_z)
  return text
end

local function run_visual_selection_in_terminal()
  local text = get_visual_text()
  if text == "" then
    leave_visual_mode()
    return
  end

  local function send_to_terminal(send)
    local chan = ensure_terminal_channel()
    if not chan then
      print("Could not open terminal")
      return false
    end

    local payload = send
    if not payload:match("\n$") then
      payload = payload .. "\n"
    end
    vim.fn.chansend(chan, payload)
    return true
  end

  send_to_terminal(text)
  leave_visual_mode()
end

local function send_to_terminal(send)
  local chan = ensure_terminal_channel()
  if not chan then
    print("Could not open terminal")
    return false
  end

  local payload = send
  if not payload:match("\n$") then
    payload = payload .. "\n"
  end

  vim.fn.chansend(chan, payload)
  return true
end

local function find_terminal_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == "terminal" then
      return win
    end
  end

  return nil
end

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

local function run_command_in_terminal(command, path_for_root)
  local function ensure_right_split_terminal_channel()
    local existing_win = find_terminal_window()
    if existing_win and vim.api.nvim_win_is_valid(existing_win) then
      local existing_chan = buf_terminal_channel(vim.api.nvim_win_get_buf(existing_win))
      if existing_chan then
        return existing_chan
      end
    end

    local origin_win = vim.api.nvim_get_current_win()
    vim.cmd("botright vsplit")
    vim.cmd("terminal")

    local bufnr = vim.api.nvim_get_current_buf()
    local chan = nil
    for _ = 1, 30 do
      local ok, new_chan = pcall(vim.api.nvim_buf_get_var, bufnr, "terminal_job_id")
      if ok and new_chan and job_running(new_chan) then
        chan = new_chan
        break
      end
      vim.wait(20)
    end

    if origin_win and vim.api.nvim_win_is_valid(origin_win) then
      vim.api.nvim_set_current_win(origin_win)
    end

    return chan
  end

  local root = project_root_for_path(path_for_root or "")
  local full = string.format("cd %s && %s", vim.fn.shellescape(root), command)
  local chan = ensure_right_split_terminal_channel()
  if not chan then
    print("Could not open terminal")
    return
  end

  if not full:match("\n$") then
    full = full .. "\n"
  end
  vim.fn.chansend(chan, full)
end

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

local function run_pytest_all()
  run_command_in_terminal("poetry run pytest", vim.fn.expand("%:p"))
end

local function run_pytest_file()
  local file = vim.fn.expand("%:p")
  if file == "" then
    print("No file in current buffer")
    return
  end
  run_command_in_terminal("poetry run pytest " .. vim.fn.shellescape(file), file)
end

local function run_pytest_nearest()
  local mode = vim.fn.mode()
  if mode:match("[vV\22]") then
    local start_pos = vim.api.nvim_buf_get_mark(0, "<")
    if start_pos[1] > 0 then
      vim.api.nvim_win_set_cursor(0, { start_pos[1], start_pos[2] })
    end
    leave_visual_mode()
  end

  local nodeid = nearest_pytest_nodeid()
  local file = vim.fn.expand("%:p")
  if not nodeid then
    print("Could not find nearest test_* function")
    return
  end

  run_command_in_terminal("poetry run pytest " .. vim.fn.shellescape(nodeid), file)
end

local function run_ruff_fix_current_file()
  local file = vim.fn.expand("%:p")
  if file == "" then
    print("No file in current buffer")
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].modified then
    vim.cmd("write")
  end

  run_command_in_terminal("poetry run ruff check --fix " .. vim.fn.shellescape(file), file)

  -- Ruff runs asynchronously in terminal; check and reload buffer after it likely completes.
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == file and not vim.bo[bufnr].modified then
      vim.cmd("checktime " .. bufnr)
    end
  end, 1200)

  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == file and not vim.bo[bufnr].modified then
      vim.cmd("checktime " .. bufnr)
    end
  end, 2500)
end

-- Core keybindings
map("n", "<leader>e", "<cmd>Ex<CR>", { desc = "File explorer" })
map("i", "jk", "<Esc>", { desc = "Leave insert mode" })
map("n", "`", "<cmd>NvimTreeToggle<CR>", { desc = "Toggle tree" })

-- CodeCompanion
map({ "n", "v" }, "<C-l>", open_codecompanion_chat_with_selection, { desc = "CodeCompanion chat with selection" })
map({ "n", "v" }, "<C-k>", cc_k.short_explain, { desc = "CodeCompanion short explain (K window)" })
map("n", "<leader>cc", "<cmd>CodeCompanionChat<CR>", { desc = "CodeCompanion chat" })
map("v", "<leader>ca", "<cmd>CodeCompanionActions<CR>", { desc = "CodeCompanion actions" })

-- Diagnostics
vim.o.updatetime = 300
vim.api.nvim_create_autocmd("CursorHold", { callback = open_diagnostics_float })

-- Terminal tab navigation
map("t", "<C-b>n", function()
  leave_terminal_mode()
  tab_terminal_next(1)
end)

map("t", "<C-b>p", function()
  leave_terminal_mode()
  tab_terminal_next(-1)
end)

map("n", "<C-b>n", function()
  tab_terminal_next(1)
end)

map("n", "<C-b>p", function()
  tab_terminal_next(-1)
end)

map("n", "<C-b>c", open_new_terminal_tab, { desc = "Open terminal tab" })
map("n", "<C-b>v", open_terminal_vsplit_and_return_focus, { desc = "Open terminal vsplit (keep focus)" })
map("n", "<leader>r", toggle_terminal_vsplit_and_return_focus, { desc = "Toggle terminal vsplit" })
map("v", "<leader>r", run_visual_selection_in_terminal, { desc = "Run selection in terminal" })

-- Pytest (Poetry)
map("n", "<leader>ta", run_pytest_all, { desc = "Pytest all (poetry)" })
map("n", "<leader>tf", run_pytest_file, { desc = "Pytest file (poetry)" })
map({ "n", "v" }, "<leader>tn", run_pytest_nearest, { desc = "Pytest nearest (poetry)" })
map("n", "<leader>rx", run_ruff_fix_current_file, { desc = "Ruff check --fix (poetry)" })
