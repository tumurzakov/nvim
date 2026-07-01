local M = {}

local TOOL_PERMISSIONS = "@{read_file} @{grep_search} @{file_search}"

local function current_symbol()
  return vim.fn.expand("<cword>")
end

local function feedkeys(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "n", false)
end

-- Read the live visual selection using the anchor (getpos "v") and cursor,
-- NOT the stale '< '> marks which only update after leaving visual mode.
-- Returns: text, start_line (1-based), end_line (1-based)
local function get_live_visual_selection()
  local mode = vim.fn.mode()
  local anchor = vim.fn.getpos("v")
  local cur = vim.fn.getpos(".")
  -- getpos cols are 1-based
  local a_line, a_col = anchor[2], anchor[3]
  local c_line, c_col = cur[2], cur[3]

  local start_line, start_col, end_line, end_col
  if a_line < c_line or (a_line == c_line and a_col <= c_col) then
    start_line, start_col = a_line, a_col
    end_line,   end_col   = c_line, c_col
  else
    start_line, start_col = c_line, c_col
    end_line,   end_col   = a_line, a_col
  end

  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  if vim.tbl_isempty(lines) then
    return nil, start_line, end_line
  end

  if mode ~= "V" then
    lines[#lines] = string.sub(lines[#lines], 1, end_col)
    lines[1]      = string.sub(lines[1], start_col)
  end

  return table.concat(lines, "\n"), start_line, end_line
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

-- sel_start / sel_end: live 1-based line numbers captured before leaving visual mode
local function get_diagnostics_for_context(sel_start, sel_end)
  local mode = vim.fn.mode()
  local has_selection = mode:match("[vV\22]") ~= nil
  local diags

  if has_selection and sel_start then
    diags = vim.diagnostic.get(0, { lnum = sel_start - 1, end_lnum = sel_end })
  elseif has_selection then
    local anchor = vim.fn.getpos("v")
    local cur    = vim.fn.getpos(".")
    local start_line = math.min(anchor[2], cur[2]) - 1
    local end_line   = math.max(anchor[2], cur[2]) - 1
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
  local filetype = vim.bo.filetype
  local mode = vim.fn.mode()
  local has_selection = mode:match("[vV\22]") ~= nil

  -- Capture selection via live positions BEFORE exiting visual mode.
  -- The '< '> marks are stale until after Escape is processed.
  local selection, sel_start, sel_end
  if has_selection then
    selection, sel_start, sel_end = get_live_visual_selection()
  end
  local diags = get_diagnostics_for_context(sel_start, sel_end)

  if has_selection then
    feedkeys("<Esc>")
  end

  local prompt_lines = {
    "Explain the meaning, intent, and implications of what is under the cursor or selected.",
    "Write for an experienced developer. Skip the obvious: do NOT state that it is a comment, "
      .. "keyword, variable, or function, do NOT restate the syntax, and do NOT explain basic "
      .. "language mechanics. If the whole answer would be obvious, say so in one line instead of padding.",
    "Focus on substance: what it actually refers to, WHY it exists, the domain meaning, the specific "
      .. "case or edge case it handles, and any non-obvious consequences or gotchas. For a comment, "
      .. "explain the situation it describes and why that matters — not that it is a comment.",
    "If the file is on disk, use the read tools to read the surrounding code for real context instead "
      .. "of guessing. If context is genuinely unavailable, say so in one line and give your best inference.",
    "Be concise and concrete. Lead with the point, not a preamble.",
    "Never use markdown tables or pipe-separated rows. Use bullet lists or labeled lines instead.",
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
    -- Fence the selection with the buffer's real filetype (e.g. ```terraform)
    -- so it is the single, language-tagged block in the prompt.
    local fence = (filetype ~= "" and filetype) or "text"
    table.insert(prompt_lines, "Selected text:\n```" .. fence .. "\n" .. selection .. "\n```")
  end

  local prompt = table.concat(prompt_lines, "\n")

  -- We insert the selection ourselves (above). Force is_visual=false on the
  -- context handed to CodeCompanion so it does NOT auto-insert the selection a
  -- second time as its own ```<filetype>``` block. The public chat() API drops
  -- `stop_context_insertion`, so that flag has no effect — overriding the
  -- context's is_visual is the only reliable lever (see ui/init.lua render()).
  local buffer_context = require("codecompanion.utils.context").get(0)
  buffer_context.is_visual = false
  buffer_context.is_normal = true

  local chat = codecompanion.chat({
    auto_submit = true,
    context = buffer_context,
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
