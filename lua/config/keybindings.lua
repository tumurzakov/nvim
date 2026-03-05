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

  if has_selection then
    leave_visual_mode()
  end

  local selection = has_selection and get_visual_selection_from_marks() or nil

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

local function rewrite_visual_selection_with_codecompanion()
  local visual_mode = vim.fn.mode()
  if not visual_mode:match("[vV\22]") then
    vim.notify("Use this mapping in visual mode", vim.log.levels.WARN)
    return
  end

  local selected = get_visual_selection_from_marks()
  if not selected or vim.trim(selected) == "" then
    vim.notify("No selected text", vim.log.levels.WARN)
    return
  end

  local commands = {}
  for cmd in selected:gmatch("!([^!\n]+)!") do
    local trimmed = vim.trim(cmd)
    if trimmed ~= "" then
      table.insert(commands, trimmed)
    end
  end

  local ok_context, context_utils = pcall(require, "codecompanion.utils.context")
  local ok_inline, inline_mod = pcall(require, "codecompanion.interactions.inline")
  if not (ok_context and ok_inline) then
    vim.notify("CodeCompanion inline is not available", vim.log.levels.ERROR)
    return
  end

  local function open_status_window()
    local ui = {}
    ui.bufnr = vim.api.nvim_create_buf(false, true)
    if not ui.bufnr then
      return nil
    end

    local width = math.max(40, math.floor(vim.o.columns * 0.38))
    local height = 6
    local row = math.floor((vim.o.lines - height) / 2 - 1)
    local col = math.floor((vim.o.columns - width) / 2)

    ui.winnr = vim.api.nvim_open_win(ui.bufnr, false, {
      relative = "editor",
      row = math.max(0, row),
      col = math.max(0, col),
      width = width,
      height = height,
      style = "minimal",
      border = "rounded",
      title = " CodeCompanion ",
      title_pos = "center",
      focusable = false,
      noautocmd = true,
    })
    if not ui.winnr or not vim.api.nvim_win_is_valid(ui.winnr) then
      pcall(vim.api.nvim_buf_delete, ui.bufnr, { force = true })
      return nil
    end

    vim.bo[ui.bufnr].buftype = "nofile"
    vim.bo[ui.bufnr].bufhidden = "wipe"
    vim.bo[ui.bufnr].swapfile = false
    vim.bo[ui.bufnr].modifiable = false

    ui.spinner_frames = { "-", "\\", "|", "/" }
    ui.spinner_idx = 1
    ui.phase = "Preparing request..."

    ui.render = function()
      if not (ui.bufnr and vim.api.nvim_buf_is_valid(ui.bufnr)) then
        return
      end
      vim.bo[ui.bufnr].modifiable = true
      local frame = ui.spinner_frames[ui.spinner_idx]
      vim.api.nvim_buf_set_lines(ui.bufnr, 0, -1, false, {
        "",
        "  " .. frame .. "  " .. ui.phase,
        "",
        "  Running inline rewrite on selected text...",
        "",
      })
      vim.bo[ui.bufnr].modifiable = false
    end

    ui.set_phase = function(phase)
      ui.phase = phase
      ui.render()
    end

    ui.timer = vim.uv.new_timer()
    if ui.timer then
      ui.timer:start(0, 120, vim.schedule_wrap(function()
        ui.spinner_idx = (ui.spinner_idx % #ui.spinner_frames) + 1
        ui.render()
      end))
    end

    ui.close = function()
      if ui.timer then
        ui.timer:stop()
        ui.timer:close()
        ui.timer = nil
      end
      if ui.winnr and vim.api.nvim_win_is_valid(ui.winnr) then
        pcall(vim.api.nvim_win_close, ui.winnr, true)
      end
      if ui.bufnr and vim.api.nvim_buf_is_valid(ui.bufnr) then
        pcall(vim.api.nvim_buf_delete, ui.bufnr, { force = true })
      end
    end

    ui.render()
    return ui
  end

  local status_ui = open_status_window()
  local target_bufnr = vim.api.nvim_get_current_buf()
  local context = context_utils.get(target_bufnr, { range = 2 })
  leave_visual_mode()

  local prompt_lines = {
    "Rewrite ONLY the selected text and replace selection with result.",
    "You may shorten, expand, or restructure the selected text, including adding/removing lines.",
    "Do not modify any text outside the selected range.",
    "Default behavior (when no explicit command): translate to English, then improve grammar and clarity.",
    "Preserve meaning and facts unchanged.",
    "Never invent details, entities, numbers, or claims that are not in the selected text.",
    "Keep text close to the original wording and tone.",
    "If the selected text includes !command! markers, execute those commands.",
    "Never include !command! markers in final output.",
    "Return ONLY final text. No markdown fences. No explanations.",
  }

  if #commands > 0 then
    table.insert(prompt_lines, "")
    table.insert(prompt_lines, "Detected commands:")
    for _, cmd in ipairs(commands) do
      table.insert(prompt_lines, "- " .. cmd)
    end
  end

  local prompt = table.concat(prompt_lines, "\n")
    .. "\n\nSelected text:\n```text\n"
    .. selected
    .. "\n```"
  local augroup = vim.api.nvim_create_augroup("cc_inline_rewrite_status_" .. tostring(vim.uv.hrtime()), { clear = true })
  local function close_status()
    if status_ui then
      status_ui.close()
    end
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
  end

  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "CodeCompanionRequestStarted",
    callback = function(ev)
      if ev.data and ev.data.interaction == "inline" and status_ui then
        status_ui.set_phase("Sending request to model...")
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "CodeCompanionRequestFinished",
    callback = function(ev)
      if ev.data and ev.data.interaction == "inline" and status_ui then
        status_ui.set_phase("Patch generated. Confirm with gda / gdr...")
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "CodeCompanionInlineFinished",
    callback = function()
      close_status()
    end,
  })

  if status_ui then
    status_ui.set_phase("Waiting for model...")
  end

  local inline = inline_mod.new({
    buffer_context = context,
    opts = { placement = "replace" },
    placement = "replace",
  })

  if not inline then
    if status_ui then
      status_ui.close()
    end
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    vim.notify("Failed to start CodeCompanion inline", vim.log.levels.ERROR)
    return
  end

  inline:prompt(prompt)
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

local shared_terminal_bufnr = nil

local function shared_terminal_layout(win)
  local ok, layout = pcall(vim.api.nvim_win_get_var, win, "cc_terminal_layout")
  if ok then
    return layout
  end
  return nil
end

local function find_shared_terminal_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local ok, is_shared = pcall(vim.api.nvim_win_get_var, win, "cc_shared_terminal")
    if vim.bo[buf].buftype == "terminal" and ok and is_shared then
      return win
    end
  end
  return nil
end

local function open_or_toggle_shared_terminal(layout)
  local origin_win = vim.api.nvim_get_current_win()

  local existing_win = find_shared_terminal_window()
  if existing_win and vim.api.nvim_win_is_valid(existing_win) then
    local existing_layout = shared_terminal_layout(existing_win)
    if existing_layout == layout then
      vim.api.nvim_win_close(existing_win, true)
      return
    end
    vim.api.nvim_win_close(existing_win, true)
  end

  if layout == "split" then
    local height = math.max(3, math.floor(vim.o.lines * 0.15))
    vim.cmd("botright " .. tostring(height) .. "split")
  else
    vim.cmd("botright vsplit")
  end

  local term_win = vim.api.nvim_get_current_win()
  if shared_terminal_bufnr and vim.api.nvim_buf_is_valid(shared_terminal_bufnr) then
    vim.api.nvim_win_set_buf(term_win, shared_terminal_bufnr)
  else
    vim.cmd("terminal")
    shared_terminal_bufnr = vim.api.nvim_get_current_buf()
    vim.bo[shared_terminal_bufnr].bufhidden = "hide"
  end

  pcall(vim.api.nvim_win_set_var, term_win, "cc_shared_terminal", true)
  pcall(vim.api.nvim_win_set_var, term_win, "cc_terminal_layout", layout)

  if origin_win and vim.api.nvim_win_is_valid(origin_win) then
    vim.api.nvim_set_current_win(origin_win)
  end
end

local function open_terminal_vsplit_and_return_focus()
  open_or_toggle_shared_terminal("vsplit")
end

local function toggle_terminal_split_and_return_focus()
  open_or_toggle_shared_terminal("split")
end

local function toggle_terminal_vsplit_and_return_focus()
  open_or_toggle_shared_terminal("vsplit")
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
  local file = vim.fn.expand("%:p")
  run_command_in_terminal(build_pytest_command("", file), file)
end

local function run_pytest_file()
  local file = vim.fn.expand("%:p")
  if file == "" then
    print("No file in current buffer")
    return
  end
  run_command_in_terminal(build_pytest_command(vim.fn.shellescape(file), file), file)
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

  run_command_in_terminal(build_pytest_command(vim.fn.shellescape(nodeid), file), file)
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

  run_command_in_terminal(build_ruff_command("check --fix " .. vim.fn.shellescape(file), file), file)

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

local function run_current_python_script()
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

  run_command_in_terminal(build_python_command(vim.fn.shellescape(file), file), file)
end

local function reload_nvim_config()
  if vim.g.__nvim_config_reloading then
    vim.notify("Reload already in progress", vim.log.levels.WARN)
    return
  end

  vim.g.__nvim_config_reloading = true

  vim.schedule(function()
    local errors = {}
    local reloaded_plugins = 0

    local function run_step(fn)
      local ok, err = pcall(fn)
      if not ok then
        table.insert(errors, tostring(err))
      end
    end

    run_step(function()
      for module, _ in pairs(package.loaded) do
        if module:match("^config%.") then
          package.loaded[module] = nil
        end
      end
      require("config.options")
      require("config.keybindings")
    end)

    run_step(function()
      local ok_plugin, plugin = pcall(require, "lazy.core.plugin")
      if not ok_plugin then
        return
      end

      plugin.load()
      reloaded_plugins = vim.tbl_count(require("lazy.core.config").plugins or {})
      pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "LazyReload", modeline = false })
    end)

    vim.g.__nvim_config_reloading = false

    if #errors > 0 then
      vim.notify("Config reload failed:\n" .. table.concat(errors, "\n"), vim.log.levels.ERROR)
      return
    end

    vim.notify(string.format("Neovim config reloaded (%d plugins)", reloaded_plugins), vim.log.levels.INFO)
  end)
end

local function telescope_call(picker)
  return function()
    local ok, builtin = pcall(require, "telescope.builtin")
    if not ok then
      vim.notify("Telescope is not available", vim.log.levels.ERROR)
      return
    end
    builtin[picker]()
  end
end

-- Core keybindings
map("n", "<leader>e", "<cmd>Ex<CR>", { desc = "File explorer" })
map("i", "jk", "<Esc>", { desc = "Leave insert mode" })
map("n", "<leader>tt", "<cmd>NvimTreeToggle<CR>", { desc = "Toggle tree" })
map("n", "<F9>", "<cmd>AerialToggle!<CR>", { desc = "Toggle aerial" })
map("n", "<leader>ff", telescope_call("find_files"), { desc = "Find files (Telescope)" })
map("n", "<leader>fg", telescope_call("live_grep"), { desc = "Live grep (Telescope)" })
map("n", "<leader>fb", telescope_call("buffers"), { desc = "Buffers (Telescope)" })
map("n", "<leader>fh", telescope_call("help_tags"), { desc = "Help tags (Telescope)" })

-- CodeCompanion
map({ "n", "v" }, "<C-l>", open_codecompanion_chat_with_selection, { desc = "CodeCompanion chat with selection" })
map({ "n", "v" }, "<C-k>", cc_k.short_explain, { desc = "CodeCompanion short explain (K window)" })
map("v", "<leader>ci", rewrite_visual_selection_with_codecompanion, { desc = "Rewrite selected text (CodeCompanion)" })
map("n", "<leader>cc", "<cmd>CodeCompanionChat<CR>", { desc = "CodeCompanion chat" })
map("n", "<leader>cm", "<cmd>CodeCompanion /commit<CR>", { desc = "CodeCompanion commit message" })
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
map("n", "<leader>r", toggle_terminal_split_and_return_focus, { desc = "Toggle terminal split (15%)" })
map("n", "<leader>rv", toggle_terminal_vsplit_and_return_focus, { desc = "Toggle terminal vsplit" })
map("v", "<leader>r", run_visual_selection_in_terminal, { desc = "Run selection in terminal" })

-- Python tools (prefer Poetry when available)
map("n", "<leader>ta", run_pytest_all, { desc = "Pytest all" })
map("n", "<leader>tf", run_pytest_file, { desc = "Pytest file" })
map({ "n", "v" }, "<leader>tn", run_pytest_nearest, { desc = "Pytest nearest" })
map("n", "<leader>rx", run_ruff_fix_current_file, { desc = "Ruff check --fix" })
map("n", "<leader>x", run_current_python_script, { desc = "Run current Python file" })

pcall(vim.api.nvim_del_user_command, "ReloadConfig")
vim.api.nvim_create_user_command("ReloadConfig", reload_nvim_config, {
  desc = "Reload Neovim config and Lazy specs",
})

-- Local (git-ignored) settings overrides: lua/config/settings_local.lua
local ok_local, settings_local = pcall(require, "config.settings_local")
if ok_local and settings_local.keybindings and type(settings_local.keybindings.apply) == "function" then
  settings_local.keybindings.apply(map)
end
