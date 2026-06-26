local default_opts = { noremap = true, silent = true }
local cc_k = require("config.codecompanion_k")

local function map(mode, lhs, rhs, opts)
  vim.keymap.set(mode, lhs, rhs, vim.tbl_extend("force", default_opts, opts or {}))
end

local function feedkeys(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "n", false)
end

local function feedkeys_sync(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "nx", false)
end

local function leave_visual_mode()
  feedkeys_sync("<Esc>")
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

local function open_codecompanion_chat_with_review_context()
  local mode = vim.fn.mode()
  if not mode:match("[vV\22]") then
    vim.notify("Use \\cq in visual mode (e.g. in a gR review pane)", vim.log.levels.WARN)
    return
  end
  leave_visual_mode()

  local bufnr = vim.api.nvim_get_current_buf()
  local start_pos = vim.api.nvim_buf_get_mark(bufnr, "<")
  local end_pos = vim.api.nvim_buf_get_mark(bufnr, ">")
  local selection = get_visual_selection_from_marks() or ""

  local rc = require("config.review_context")
  local ctx = rc.fallback()
  local path = (ctx and ctx.file) or vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":.")

  local parts = {}
  if ctx then
    table.insert(parts, string.format(
      "Reviewing `%s` vs `%s` in repo `%s`.",
      ctx.right_display, ctx.left_display, rc.repo_name(ctx.root)
    ))
    local subjects = rc.commit_subjects(ctx.root, ctx.left_sha, ctx.right_sha, 30)
    local subjects_block = rc.format_subjects(subjects)
    if subjects_block then
      table.insert(parts, "")
      table.insert(parts, string.format("Commits in this range (%d):", #subjects))
      table.insert(parts, subjects_block)
    end
    table.insert(parts, "")
    table.insert(parts, string.format("File: `%s`, lines %d-%d.", path, start_pos[1], end_pos[1]))

    local diff = rc.diff(ctx.root, ctx.left_sha, ctx.right_sha, ctx.file, { right_is_local = ctx.right_is_local })
    if diff and diff ~= "" then
      table.insert(parts, "")
      table.insert(parts, "Diff for this file:")
      table.insert(parts, "```diff")
      table.insert(parts, diff)
      table.insert(parts, "```")
    end
  else
    table.insert(parts, string.format("Reviewing `%s` lines %d-%d.", path, start_pos[1], end_pos[1]))
  end

  table.insert(parts, "")
  table.insert(parts, string.format("My question is about lines %d-%d:", start_pos[1], end_pos[1]))
  table.insert(parts, "```")
  table.insert(parts, selection)
  table.insert(parts, "```")
  table.insert(parts, "")

  local content = table.concat(parts, "\n")

  local cc = require("codecompanion")
  local chat = cc.chat({
    messages = { { role = "user", content = content } },
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

-- Dedicated "run" terminal for <leader>r / <leader>rl. It is tagged with a
-- buffer-local flag so it is never confused with a \T repo terminal or a
-- `C-b c` terminal tab — running a selection must NEVER silently hijack an
-- unrelated shell.
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

  -- None yet: open a fresh, visible run-terminal in a right split and tag it.
  vim.cmd("botright vsplit")
  vim.cmd("terminal")

  local bufnr = vim.api.nvim_get_current_buf()
  pcall(vim.api.nvim_buf_set_var, bufnr, RUN_TERM_VAR, true)

  local new_chan
  for _ = 1, 30 do
    local ok, c = pcall(vim.api.nvim_buf_get_var, bufnr, "terminal_job_id")
    if ok and c and job_running(c) then
      new_chan = c
      break
    end
    vim.wait(20)
  end

  if vim.api.nvim_win_is_valid(origin) then
    vim.api.nvim_set_current_win(origin)
  end

  return new_chan
end

local function get_visual_text()
  local reg_z = vim.fn.getreginfo("z")
  vim.cmd('silent normal! "zy')
  local text = vim.fn.getreg("z")
  vim.fn.setreg("z", reg_z)
  return text
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

local function send_to_terminal(send)
  local chan = ensure_run_terminal_channel()
  if not chan then
    print("Could not open terminal")
    return false
  end

  local payload = send
  if not payload:match("\n$") then
    payload = payload .. "\n"
  end

  vim.fn.chansend(chan, payload)
  vim.schedule(function() scroll_terminal_to_bottom(chan) end)
  return true
end

local function run_visual_selection_in_terminal()
  local text = get_visual_text()
  if text == "" then
    leave_visual_mode()
    return
  end

  send_to_terminal(text)
  leave_visual_mode()
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
  vim.schedule(function() scroll_terminal_to_bottom(chan) end)
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

-- Toggle zoom current split
local function toggle_zoom()
  if vim.t.zoomed then
    vim.cmd(vim.t.zoom_restore)
    vim.t.zoomed = false
  else
    vim.t.zoom_restore = vim.fn.winrestcmd()
    vim.cmd("wincmd _")
    vim.cmd("wincmd |")
    vim.t.zoomed = true
  end
end

-- Toggle focus between NvimTree and source window
local last_source_win = nil
local function toggle_nvimtree_focus()
  local nvimtree_api_ok, nvimtree_api = pcall(require, "nvim-tree.api")
  if not nvimtree_api_ok then
    return
  end

  local cur_win = vim.api.nvim_get_current_win()
  local cur_buf = vim.api.nvim_win_get_buf(cur_win)
  local is_tree = vim.bo[cur_buf].filetype == "NvimTree"

  if is_tree then
    -- Go back to source window
    if last_source_win and vim.api.nvim_win_is_valid(last_source_win) then
      vim.api.nvim_set_current_win(last_source_win)
    else
      vim.cmd("wincmd l")
    end
  else
    -- Remember source window, then focus tree (open if needed)
    last_source_win = cur_win
    local tree_visible = nvimtree_api.tree.is_visible()
    if tree_visible then
      nvimtree_api.tree.focus()
    else
      nvimtree_api.tree.open()
    end
  end
end

-- Core keybindings
map("n", "<leader>e", "<cmd>Ex<CR>", { desc = "File explorer" })
map("i", "jk", "<Esc>", { desc = "Leave insert mode" })
map("n", "<leader>tt", "<cmd>NvimTreeToggle<CR>", { desc = "Toggle tree" })
map("n", "±", toggle_nvimtree_focus, { desc = "Toggle NvimTree focus" })
map("n", "<F3>", toggle_zoom, { desc = "Toggle zoom split" })
map("n", "<F9>", "<cmd>AerialToggle!<CR>", { desc = "Toggle aerial" })
map("n", "<leader>ff", telescope_call("find_files"), { desc = "Find files (Telescope)" })
map("n", "<leader>fg", telescope_call("live_grep"), { desc = "Live grep (Telescope)" })
map("n", "<leader>fb", telescope_call("buffers"), { desc = "Buffers (Telescope)" })
map("n", "<leader>fh", telescope_call("help_tags"), { desc = "Help tags (Telescope)" })

-- Repo terminal: \T from a normal file opens/focuses the shared terminal for
-- the current file's git repo; pressing it again from that terminal jumps back
-- to the file. (In nvim-tree, \T is buffer-local and acts on the node instead.)
map("n", "<leader>T", function()
  local st = require("config.shared_term")
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo.buftype == "terminal" and st.is_shared(buf) then
    if not st.toggle_back() then vim.cmd("wincmd p") end   -- back to the file
    return
  end
  local file = vim.api.nvim_buf_get_name(buf)
  local dir = (file ~= "" and vim.fn.filereadable(file) == 1)
    and vim.fn.fnamemodify(file, ":h") or vim.fn.getcwd()
  local root = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "--show-toplevel" })[1]
  if type(root) == "string" and root ~= "" and not root:lower():find("fatal") then
    dir = root
  end
  st.cd(dir, { focus = true })
end, { desc = "Repo terminal: focus / back (\\T)" })

-- Terminal switcher: floating picker → show chosen terminal in the right window
map("n", "<F4>", function() require("config.term_switcher").pick() end, { desc = "Switch terminal (floating picker)" })

-- ...also reachable from INSIDE a terminal: leave terminal mode, then pick.
-- F4 (same key everywhere) and the <C-\>m chord (next to the <C-\><C-n> exit).
local function switch_terminal_from_term()
  leave_terminal_mode()
  vim.schedule(function() require("config.term_switcher").pick() end)
end
map("t", "<F4>", switch_terminal_from_term, { desc = "Switch terminal (from terminal mode)" })
map("t", "<C-\\>m", switch_terminal_from_term, { desc = "Switch terminal (from terminal mode)" })

-- Markdown
map("n", "<leader>mm", function() require("config.md_server").open() end, { desc = "Markdown view (HTTP server, live)" })
map("n", "<leader>ms", function() require("config.md_server").stop() end, { desc = "Markdown server stop" })

-- CodeCompanion
map({ "n", "v" }, "<C-l>", open_codecompanion_chat_with_selection, { desc = "CodeCompanion chat with selection" })
map({ "n", "v" }, "<C-k>", cc_k.short_explain, { desc = "CodeCompanion short explain (K window)" })
map("v", "<leader>ci", rewrite_visual_selection_with_codecompanion, { desc = "Rewrite selected text (CodeCompanion)" })
map("v", "<leader>cq", open_codecompanion_chat_with_review_context, { desc = "CodeCompanion review question (base..HEAD)" })
map("n", "<leader>cc", "<cmd>CodeCompanionChat<CR>", { desc = "CodeCompanion chat" })
map("n", "<A-l>", "<cmd>CodeCompanionChat Toggle<CR>", { desc = "Toggle CodeCompanion chat" })
map("n", "¬", "<cmd>CodeCompanionChat Toggle<CR>", { desc = "Toggle CodeCompanion chat" })
map("n", "<leader>cm", "<cmd>CodeCompanion /commit<CR>", { desc = "CodeCompanion commit message" })
map("v", "<leader>ca", "<cmd>CodeCompanionActions<CR>", { desc = "CodeCompanion actions" })

-- Close the red/green (gR) review view if it's open
map("n", "<leader>gc", function() require("config.review_view").close() end, { desc = "Close review view" })

-- Kitty drop: send text into the tagged Claude Code kitty window
map("v", "<leader>kd", function()
  -- leave visual mode so '< / '> marks are committed, then send
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
  require("config.kitty_drop").send_visual()
end, { desc = "Kitty drop: send selection to Claude tab" })
map("n", "<leader>kd", function() require("config.kitty_drop").send_lineref() end, { desc = "Kitty drop: send file:line to Claude tab" })
map("n", "<leader>kf", function() require("config.kitty_drop").send_path() end, { desc = "Kitty drop: send file path to Claude tab" })

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
map("v", "<leader>r", run_visual_selection_in_terminal, { desc = "Run selection in terminal" })
map("n", "<leader>rl", function()
  local line = vim.trim(vim.api.nvim_get_current_line())
  if line == "" then
    print("Empty line")
    return
  end
  send_to_terminal(line)
end, { desc = "Run current line in terminal" })

-- Web page summarizer
local function web_summarize(url, guidance, insert_after, indent)
  local bufnr = vim.api.nvim_get_current_buf()
  local row = insert_after or vim.api.nvim_win_get_cursor(0)[1]
  indent = indent or ""
  vim.notify("Summarizing " .. url .. "...")

  local cmd = { "python3", vim.fn.expand("~/src/context/web_summary.py"), url }
  if guidance and guidance ~= "" then
    table.insert(cmd, guidance)
  end

  local stdout_lines = {}
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" or #stdout_lines > 0 then
            table.insert(stdout_lines, line)
          end
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        -- trim trailing empty lines
        while #stdout_lines > 0 and stdout_lines[#stdout_lines] == "" do
          table.remove(stdout_lines)
        end
        if code ~= 0 or #stdout_lines == 0 then
          vim.notify("Web summary failed (exit " .. code .. ")", vim.log.levels.ERROR)
          return
        end
        if indent ~= "" then
          for i, line in ipairs(stdout_lines) do
            stdout_lines[i] = indent .. line
          end
        end
        vim.api.nvim_buf_set_lines(bufnr, row, row, false, stdout_lines)
        vim.notify("Web summary inserted (" .. #stdout_lines .. " lines)")
      end)
    end,
  })
end

local function web_summarize_action()
  local mode = vim.fn.mode()
  local url

  local guidance
  local insert_after
  local indent = ""

  -- Visual mode: selection = guidance lines + URL on first or last line
  if mode:match("[vV\22]") then
    local text = get_visual_text()
    leave_visual_mode()
    insert_after = vim.api.nvim_buf_get_mark(0, ">")[1]
    local sel_start = vim.api.nvim_buf_get_mark(0, "<")[1]
    local sel_end = insert_after
    local buf_lines = vim.api.nvim_buf_get_lines(0, sel_start - 1, sel_end, false)
    local lines = vim.split(vim.trim(text), "\n")

    -- check last line for URL first, then first line
    local url_line_idx
    for _, idx in ipairs({ #lines, 1 }) do
      if lines[idx] and lines[idx]:match("https?://.*$") then
        url_line_idx = idx
        break
      end
    end

    if url_line_idx then
      -- detect indent from the actual buffer line containing the URL
      local raw_url_line = buf_lines[url_line_idx] or ""
      indent = raw_url_line:match("^(%s*)") or ""

      url = lines[url_line_idx]:match("https?://.*$")
      table.remove(lines, url_line_idx)
      local g = vim.trim(table.concat(lines, "\n"))
      if g ~= "" then
        guidance = g
      end
    end
  end

  -- Try extracting URL from current line
  if not url or url == "" then
    local line = vim.api.nvim_get_current_line()
    url = line:match("https?://.*$")
    if url then
      indent = line:match("^(%s*)") or ""
    end
  end

  -- Prompt for URL
  if not url or url == "" then
    url = vim.fn.input("URL: ")
    if url == "" then
      return
    end
    indent = vim.api.nvim_get_current_line():match("^(%s*)") or ""
  end

  web_summarize(url, guidance, insert_after, indent)
end

map({ "n", "v" }, "<leader>ws", web_summarize_action, { desc = "Summarize web page" })

-- Python tools (prefer Poetry when available)
map("n", "<leader>ta", run_pytest_all, { desc = "Pytest all" })
map("n", "<leader>tf", run_pytest_file, { desc = "Pytest file" })
map({ "n", "v" }, "<leader>tn", run_pytest_nearest, { desc = "Pytest nearest" })
map("n", "<leader>rx", run_ruff_fix_current_file, { desc = "Ruff check --fix" })
map("n", "<leader>x", run_current_python_script, { desc = "Run current Python file" })

-- Text-to-speech (single engine via tts.py: Piper → macOS system voice).
--   F8 (normal): read from cursor paragraph-by-paragraph (auto-advance) with
--                real-time word highlighting; press again to stop.
--   F8 / \ss (visual): speak the selection.
--   \sq: stop. One job + one stop function shared by all of the above.
local tts_ns = vim.api.nvim_create_namespace("tts_highlight")
local tts_job = nil
local tts_buf = nil
local tts_continuing = false -- true = auto-advance to next paragraph
local tts_py = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/tts.py"

-- Set ElevenLabs API key once at load time
local ok_sl, sl = pcall(require, "config.settings_local")
if ok_sl and sl.elevenlabs_api_key then
  vim.env.ELEVENLABS_API_KEY = sl.elevenlabs_api_key
end

local function tts_clear()
  if tts_buf and vim.api.nvim_buf_is_valid(tts_buf) then
    vim.api.nvim_buf_clear_namespace(tts_buf, tts_ns, 0, -1)
  end
  tts_buf = nil
end

local function tts_stop()
  tts_continuing = false
  tts_clear()
  if tts_job then
    vim.fn.jobstop(tts_job)
    tts_job = nil
    return true
  end
  return false
end

local TTS_CHUNK_LIMIT = 300 -- max chars per TTS call

--- Find next chunk starting from `from_line` (0-based).
--- Collects paragraphs until reaching TTS_CHUNK_LIMIT chars or EOF.
--- Returns start_line, end_line (0-based, exclusive end) or nil if EOF.
local function tts_next_chunk(buf, from_line)
  local total = vim.api.nvim_buf_line_count(buf)
  -- Skip leading blank lines
  local start = from_line
  while start < total do
    local l = vim.api.nvim_buf_get_lines(buf, start, start + 1, false)[1]
    if not l:match("^%s*$") then break end
    start = start + 1
  end
  if start >= total then return nil end
  -- Collect lines, breaking at paragraph boundary once limit exceeded
  local finish = start
  local chars = 0
  local in_blank = false
  while finish < total do
    local l = vim.api.nvim_buf_get_lines(buf, finish, finish + 1, false)[1]
    local is_blank = l:match("^%s*$") ~= nil
    -- Break at paragraph boundary if we have enough text
    if is_blank and chars >= TTS_CHUNK_LIMIT then break end
    if not is_blank then
      chars = chars + #l + 1
    end
    in_blank = is_blank
    finish = finish + 1
  end
  -- Trim trailing blank lines from the chunk
  while finish > start do
    local l = vim.api.nvim_buf_get_lines(buf, finish - 1, finish, false)[1]
    if not l:match("^%s*$") then break end
    finish = finish - 1
  end
  if finish <= start then return nil end
  return start, finish
end

local function tts_speak_paragraph(buf, start_line, end_line)
  local lines = vim.api.nvim_buf_get_lines(buf, start_line, end_line, false)
  local text = table.concat(lines, "\n")
  if text:match("^%s*$") then
    tts_continuing = false
    return
  end

  -- Map character offset in text -> (line, col) in buffer
  local offsets = {}
  local pos = 0
  for i, line in ipairs(lines) do
    for j = 1, #line do
      offsets[pos] = { start_line + i - 1, j - 1 }
      pos = pos + 1
    end
    offsets[pos] = { start_line + i - 1, #line }
    pos = pos + 1
  end

  tts_buf = buf

  tts_job = vim.fn.jobstart({ "python3", tts_py }, {
    stdout_buffered = false,
    on_stderr = function(_, data)
      local msg = table.concat(data, "\n")
      if msg ~= "" then vim.schedule(function() vim.notify("TTS: " .. msg, vim.log.levels.WARN) end) end
    end,
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        if line == "DONE" or line == "" then
          -- done
        else
          local offset, length = line:match("^(%d+)%s+(%d+)$")
          if offset then
            offset = tonumber(offset)
            length = tonumber(length)
            vim.schedule(function()
              if not tts_buf or not vim.api.nvim_buf_is_valid(tts_buf) then return end
              vim.api.nvim_buf_clear_namespace(tts_buf, tts_ns, 0, -1)
              local start_pos = offsets[offset]
              local end_pos = offsets[offset + length] or offsets[offset + length - 1]
              if start_pos then
                local end_col = end_pos and end_pos[2] or (start_pos[2] + length)
                local end_row = end_pos and end_pos[1] or start_pos[1]
                if end_row == start_pos[1] then
                  pcall(vim.api.nvim_buf_add_highlight, tts_buf, tts_ns, "Visual", start_pos[1], start_pos[2], end_col)
                else
                  pcall(vim.api.nvim_buf_add_highlight, tts_buf, tts_ns, "Visual", start_pos[1], start_pos[2], -1)
                end
                pcall(vim.api.nvim_win_set_cursor, 0, { start_pos[1] + 1, start_pos[2] })
              end
            end)
          end
        end
      end
    end,
    on_exit = function()
      tts_job = nil
      vim.schedule(function()
        tts_clear()
        -- Auto-advance to next paragraph if not stopped
        if tts_continuing and buf and vim.api.nvim_buf_is_valid(buf) then
          local next_start, next_end = tts_next_chunk(buf, end_line)
          if next_start then
            tts_speak_paragraph(buf, next_start, next_end)
          else
            tts_continuing = false
          end
        end
      end)
    end,
  })
  vim.fn.chansend(tts_job, text)
  vim.fn.chanclose(tts_job, "stdin")
end

-- Speak the visual selection as a single chunk (no auto-advance).
local function tts_speak_selection()
  tts_stop()
  local buf = vim.api.nvim_get_current_buf()
  local start_pos = vim.api.nvim_buf_get_mark(buf, "<")
  local end_pos = vim.api.nvim_buf_get_mark(buf, ">")
  if start_pos[1] == 0 then return end
  tts_continuing = false
  tts_speak_paragraph(buf, start_pos[1] - 1, end_pos[1])
end

-- F8 (normal): toggle — read from cursor paragraph-by-paragraph, or stop.
map("n", "<F8>", function()
  if tts_stop() then return end
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local start, finish = tts_next_chunk(buf, cursor[1] - 1)
  if not start then return end
  tts_continuing = true
  tts_speak_paragraph(buf, start, finish)
end, { desc = "TTS: read from cursor / stop" })

-- Visual selection → speak (F8 or \ss share the same engine + highlighting).
local function tts_selection_mapping()
  leave_visual_mode()
  vim.schedule(tts_speak_selection)
end
map("v", "<F8>", tts_selection_mapping, { desc = "TTS: speak selection" })
map("v", "<leader>ss", tts_selection_mapping, { desc = "TTS: speak selection" })

-- Stop from anywhere (also stops an in-progress F8 read).
map({ "n", "v" }, "<leader>sq", function() tts_stop() end, { desc = "TTS: stop speaking" })

pcall(vim.api.nvim_del_user_command, "ReloadConfig")
vim.api.nvim_create_user_command("ReloadConfig", reload_nvim_config, {
  desc = "Reload Neovim config and Lazy specs",
})

-- Local (git-ignored) settings overrides: lua/config/settings_local.lua
local ok_local, settings_local = pcall(require, "config.settings_local")
if ok_local and settings_local.keybindings and type(settings_local.keybindings.apply) == "function" then
  settings_local.keybindings.apply(map)
end
