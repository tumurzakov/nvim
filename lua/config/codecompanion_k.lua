local M = {}

local TOOL_PERMISSIONS = "@{read_file} @{grep_search} @{file_search}"

local function current_symbol()
  return vim.fn.expand("<cword>")
end

local function feedkeys(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "n", false)
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

local function current_context()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  local filename = vim.api.nvim_buf_get_name(0)

  return {
    filename = filename ~= "" and filename or "[No Name]",
    line_no = cursor[1],
    line_text = line,
  }
end

local function severity_name(sev)
  local names = vim.diagnostic.severity
  if sev == names.ERROR then
    return "ERROR"
  end
  if sev == names.WARN then
    return "WARN"
  end
  if sev == names.INFO then
    return "INFO"
  end
  if sev == names.HINT then
    return "HINT"
  end
  return "UNKNOWN"
end

local function format_diag(diag)
  local src = diag.source or "unknown"
  local code = diag.code and ("(" .. tostring(diag.code) .. ")") or ""
  local line = (diag.lnum or 0) + 1
  return string.format("[%s] %s%s L%d: %s", severity_name(diag.severity), src, code, line, diag.message or "")
end

local function get_diagnostics_for_context()
  local mode = vim.fn.mode()
  local has_selection = mode:match("[vV\22]") ~= nil
  local diags

  if has_selection then
    local start_pos = vim.api.nvim_buf_get_mark(0, "<")
    local end_pos = vim.api.nvim_buf_get_mark(0, ">")
    local start_line = math.min(start_pos[1], end_pos[1]) - 1
    local end_line = math.max(start_pos[1], end_pos[1]) - 1
    diags = vim.diagnostic.get(0, { lnum = start_line, end_lnum = end_line + 1 })
  else
    local line = vim.api.nvim_win_get_cursor(0)[1] - 1
    diags = vim.diagnostic.get(0, { lnum = line })
    if #diags == 0 then
      local col = vim.api.nvim_win_get_cursor(0)[2]
      diags = vim.diagnostic.get(0, { lnum = line, col = col })
    end
  end

  table.sort(diags, function(a, b)
    if (a.lnum or 0) == (b.lnum or 0) then
      return (a.severity or 99) < (b.severity or 99)
    end
    return (a.lnum or 0) < (b.lnum or 0)
  end)

  return diags
end

function M.short_explain()
  local ok, codecompanion = pcall(require, "codecompanion")
  if not ok then
    vim.notify("CodeCompanion is not available", vim.log.levels.ERROR)
    return
  end

  local symbol = current_symbol()
  local ctx = current_context()
  local mode = vim.fn.mode()
  local has_selection = mode:match("[vV\22]") ~= nil
  local selection = has_selection and get_visual_selection_from_marks() or nil
  local diags = get_diagnostics_for_context()

  if has_selection then
    feedkeys("<Esc>")
  end

  local prompt_lines = {
    "Give a short explanation for the Python symbol/class under cursor.",
    "Keep it concise (max 6 bullets).",
    "Allowed permissions/tools only: " .. TOOL_PERMISSIONS .. ".",
    "Do not use any other tool, especially container.exec.",
    "",
    "Symbol: " .. symbol,
    "File: " .. ctx.filename,
    "Line: " .. tostring(ctx.line_no),
    "Current line: " .. ctx.line_text,
  }

  if #diags > 0 then
    table.insert(prompt_lines, "")
    table.insert(prompt_lines, "Diagnostics from Neovim/LSP/linters:")
    for _, d in ipairs(diags) do
      table.insert(prompt_lines, "- " .. format_diag(d))
    end
    table.insert(prompt_lines, "Explain each diagnostic cause and give concrete fix steps.")
  end

  if selection and selection ~= "" then
    table.insert(prompt_lines, "Selected text:\n```text\n" .. selection .. "\n```")
  end

  local prompt = table.concat(prompt_lines, "\n")

  local chat = codecompanion.chat({
    auto_submit = true,
    messages = {
      { role = "user", content = prompt },
    },
    window_opts = {
      layout = "float",
      title = "K",
      border = "rounded",
      width = 0.8,
      height = 0.8,
    },
  })

  if chat and chat.ui and chat.ui.winnr and vim.api.nvim_win_is_valid(chat.ui.winnr) then
    vim.api.nvim_set_current_win(chat.ui.winnr)
  end
end

return M
