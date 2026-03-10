local M = {}

local function project_root_from_path(path)
  local start = path ~= "" and vim.fs.dirname(vim.fs.normalize(path)) or vim.fn.getcwd()
  local git_dir = vim.fs.find(".git", { path = start, upward = true })[1]
  if git_dir then
    return vim.fs.dirname(git_dir)
  end
  return vim.fn.getcwd()
end

local function current_context_path()
  local ctx_buf = rawget(_G, "codecompanion_current_context")
  if type(ctx_buf) == "number" and vim.api.nvim_buf_is_valid(ctx_buf) then
    return vim.api.nvim_buf_get_name(ctx_buf)
  end
  return ""
end

local function chats_dir_for_root(root)
  return vim.fs.joinpath(root, ".chats")
end

local function list_chat_files(root)
  local dir = chats_dir_for_root(root)
  if vim.fn.isdirectory(dir) == 0 then
    return {}
  end
  local files = vim.fn.glob(dir .. "/*.md", false, true)
  -- Sort oldest first so index grows toward newest
  table.sort(files)
  return files
end

local function parse_chat_messages(content)
  local messages = {}
  local lines = vim.split(content, "\n")
  local current_role = nil
  local current_lines = {}

  local function flush()
    if current_role and #current_lines > 0 then
      while #current_lines > 0 and vim.trim(current_lines[#current_lines]) == "" do
        table.remove(current_lines)
      end
      if #current_lines > 0 then
        table.insert(messages, {
          role = current_role,
          content = table.concat(current_lines, "\n"),
        })
      end
    end
    current_lines = {}
  end

  for _, line in ipairs(lines) do
    if line:match("^## Me%s*$") then
      flush()
      current_role = "user"
    elseif line:match("^## CodeCompanion") then
      flush()
      current_role = "assistant"
    else
      if current_role then
        table.insert(current_lines, line)
      end
    end
  end
  flush()

  return messages
end

----------------------------------------------------------------------
-- Virtual history list
--
-- saved_files: all .chats/*.md files sorted oldest→newest
-- cursor:     index into saved_files of the currently viewed saved chat
--             nil = viewing a fresh (non-saved) chat
-- loaded:     saved_files index → bufnr (lazily populated, one at a time)
----------------------------------------------------------------------
local file_by_buf = {}
local saved_files = nil
local loaded = {}      -- file index → bufnr
local cursor = nil     -- current position in saved_files (nil = fresh chat)

local function init_saved_files()
  if saved_files then
    return
  end
  local root = project_root_from_path(current_context_path())
  saved_files = list_chat_files(root)
end

--- Materialize one saved chat into a CodeCompanion chat object.
--- Returns bufnr or nil.
local function materialize(file_idx, current_chat)
  if loaded[file_idx] then
    return loaded[file_idx]
  end

  local path = saved_files[file_idx]
  if not path then
    return nil
  end

  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  if not content or content == "" then
    return nil
  end

  local messages = parse_chat_messages(content)
  if #messages == 0 then
    return nil
  end

  local cc = require("codecompanion")
  local chat = cc.chat({
    messages = messages,
    auto_submit = false,
  })
  if not chat then
    return nil
  end

  file_by_buf[chat.bufnr] = path
  loaded[file_idx] = chat.bufnr

  -- Rename buffer to show date
  local fname = vim.fn.fnamemodify(path, ":t:r")
  local y, mo, d, h, mi = fname:match("chat_(%d%d%d%d)(%d%d)(%d%d)_(%d%d)(%d%d)")
  if y then
    pcall(vim.api.nvim_buf_set_name, chat.bufnr,
      string.format("[CodeCompanion] %s-%s-%s %s:%s", y, mo, d, h, mi))
  end

  return chat.bufnr
end

local function switch_to_buf(from_chat, target_bufnr)
  local codecompanion = require("codecompanion")
  local prev_ui = codecompanion.buf_get_chat(from_chat.bufnr).ui
  local window_opts = prev_ui.window_opts or { default = true }
  if prev_ui.win and vim.api.nvim_win_is_valid(prev_ui.win) then
    prev_ui:hide()
  end
  local target_chat = codecompanion.buf_get_chat(target_bufnr)
  if target_chat and target_chat.ui then
    target_chat.ui:open({ window_opts = window_opts })
  end
end

----------------------------------------------------------------------
-- Navigation: { = older (cursor-1), } = newer (cursor+1 or fresh)
----------------------------------------------------------------------
local function move_to_saved(chat, file_idx)
  local bufnr = materialize(file_idx, chat)
  if not bufnr then
    -- File couldn't be loaded, skip it
    return false
  end
  cursor = file_idx
  switch_to_buf(chat, bufnr)
  return true
end

M.next_chat = {
  desc = "Next chat (newer / toward fresh)",
  callback = function(chat)
    init_saved_files()

    if cursor == nil then
      -- On fresh chat, } wraps to oldest saved
      if #saved_files > 0 then
        move_to_saved(chat, 1)
      end
      return
    end

    -- Try going to a newer saved chat
    for i = cursor + 1, #saved_files do
      if move_to_saved(chat, i) then
        return
      end
    end

    -- Past newest saved → go back to fresh chats
    -- Find the fresh chat bufnr (any buf not in file_by_buf)
    local bufs = _G.codecompanion_buffers or {}
    for _, b in ipairs(bufs) do
      if not file_by_buf[b] then
        cursor = nil
        switch_to_buf(chat, b)
        return
      end
    end
  end,
}

M.previous_chat = {
  desc = "Previous chat (older)",
  callback = function(chat)
    init_saved_files()

    if cursor == nil then
      -- On fresh chat, { goes to newest saved
      for i = #saved_files, 1, -1 do
        if move_to_saved(chat, i) then
          return
        end
      end
      return
    end

    -- Try going to an older saved chat
    for i = cursor - 1, 1, -1 do
      if move_to_saved(chat, i) then
        return
      end
    end

    -- Past oldest saved → wrap to fresh chat
    local bufs = _G.codecompanion_buffers or {}
    for _, b in ipairs(bufs) do
      if not file_by_buf[b] then
        cursor = nil
        switch_to_buf(chat, b)
        return
      end
    end
  end,
}

----------------------------------------------------------------------
-- Auto-save
----------------------------------------------------------------------
function M.setup()
  if vim.g.codecompanion_chat_archive_setup then
    return
  end
  vim.g.codecompanion_chat_archive_setup = true

  local group = vim.api.nvim_create_augroup("codecompanion_chat_archive", { clear = true })
  local roots_by_buf = {}
  local tick_by_buf = {}

  local function chat_file_for_buf(bufnr)
    if file_by_buf[bufnr] then
      return file_by_buf[bufnr]
    end

    local root = roots_by_buf[bufnr]
    if not root then
      root = project_root_from_path(current_context_path())
      roots_by_buf[bufnr] = root
    end

    local chats_dir = chats_dir_for_root(root)
    vim.fn.mkdir(chats_dir, "p")

    local id = tostring(bufnr)
    local ts = os.date("%Y%m%d_%H%M%S")
    local filename = string.format("chat_%s_%s.md", ts, id)
    local path = vim.fs.joinpath(chats_dir, filename)
    file_by_buf[bufnr] = path
    return path
  end

  local function save_chat_buffer(bufnr)
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
      return
    end
    if vim.bo[bufnr].filetype ~= "codecompanion" then
      return
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if #lines == 0 then
      return
    end

    local non_empty = 0
    for _, line in ipairs(lines) do
      if vim.trim(line) ~= "" then
        non_empty = non_empty + 1
      end
    end
    if non_empty < 3 then
      return
    end

    local tick = vim.api.nvim_buf_get_changedtick(bufnr)
    if tick_by_buf[bufnr] == tick then
      return
    end

    local path = chat_file_for_buf(bufnr)
    local ok = pcall(vim.fn.writefile, lines, path)
    if ok then
      tick_by_buf[bufnr] = tick
    end
  end

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionChatCreated",
    callback = function(ev)
      local bufnr = ev.data and ev.data.bufnr or nil
      if not bufnr then
        return
      end
      roots_by_buf[bufnr] = project_root_from_path(current_context_path())
      chat_file_for_buf(bufnr)
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionChatDone",
    callback = function(ev)
      save_chat_buffer(ev.data and ev.data.bufnr)
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionChatClosed",
    callback = function(ev)
      save_chat_buffer(ev.data and ev.data.bufnr)
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        save_chat_buffer(bufnr)
      end
    end,
  })
end

return M
