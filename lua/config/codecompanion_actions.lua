-- CodeCompanion chat/inline entry points bound in keybindings:
--   chat_with_selection  (<C-l>)  — chat seeded with the visual selection,
--                                   review-aware inside a gR diff pane
--   review_question      (\cq)    — chat seeded with base..HEAD review context
--   rewrite_selection    (\ci)    — inline rewrite of the selection, with a
--                                   floating status/spinner window
local M = {}

local vu = require("config.vim_util")

local function focus_chat_and_insert(chat)
  vim.schedule(function()
    if chat and chat.ui and chat.ui.win and vim.api.nvim_win_is_valid(chat.ui.win) then
      vim.api.nvim_set_current_win(chat.ui.win)
    end
    vim.cmd("startinsert")
  end)
end

function M.chat_with_selection()
  local mode = vim.fn.mode()
  local has_selection = mode:match("[vV\22]") ~= nil

  if has_selection then
    vu.leave_visual_mode()
  end

  -- Inside a gR review diff pane the buffer is a nameless scratch buffer holding
  -- code from ANOTHER repo. A bare selection makes CodeCompanion grep the wrong
  -- (cwd) repo and conclude the code doesn't exist. Delegate to the review view's
  -- context-aware chat, which seeds repo / file / base→worktree / diff / findings.
  local bufnr = vim.api.nvim_get_current_buf()
  local rv_ok, rv = pcall(require, "config.review_view")
  if rv_ok and rv.file_for and rv.file_for(bufnr) then
    rv.codecompanion({ visual = has_selection })
    return
  end

  local selection = has_selection and vu.visual_selection() or nil

  local cc = require("codecompanion")
  local chat = cc.chat({
    messages = selection and { { role = "user", content = selection } } or nil,
    auto_submit = false,
  })
  focus_chat_and_insert(chat)
end

function M.review_question()
  local mode = vim.fn.mode()
  if not mode:match("[vV\22]") then
    vim.notify("Use \\cq in visual mode (e.g. in a gR review pane)", vim.log.levels.WARN)
    return
  end
  vu.leave_visual_mode()

  local bufnr = vim.api.nvim_get_current_buf()
  local start_pos = vim.api.nvim_buf_get_mark(bufnr, "<")
  local end_pos = vim.api.nvim_buf_get_mark(bufnr, ">")
  local selection = vu.visual_selection() or ""

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

  local cc = require("codecompanion")
  local chat = cc.chat({
    messages = { { role = "user", content = table.concat(parts, "\n") } },
    auto_submit = false,
  })
  focus_chat_and_insert(chat)
end

-- Floating status window with a spinner, used while the inline rewrite runs.
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

function M.rewrite_selection()
  local visual_mode = vim.fn.mode()
  if not visual_mode:match("[vV\22]") then
    vim.notify("Use this mapping in visual mode", vim.log.levels.WARN)
    return
  end

  local selected = vu.visual_selection()
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

  local status_ui = open_status_window()
  local target_bufnr = vim.api.nvim_get_current_buf()
  local context = context_utils.get(target_bufnr, { range = 2 })
  vu.leave_visual_mode()

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
    close_status()
    vim.notify("Failed to start CodeCompanion inline", vim.log.levels.ERROR)
    return
  end

  inline:prompt(prompt)
end

return M
