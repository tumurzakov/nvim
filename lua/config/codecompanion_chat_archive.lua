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

function M.setup()
  if vim.g.codecompanion_chat_archive_setup then
    return
  end
  vim.g.codecompanion_chat_archive_setup = true

  local group = vim.api.nvim_create_augroup("codecompanion_chat_archive", { clear = true })
  local roots_by_buf = {}
  local file_by_buf = {}
  local tick_by_buf = {}

  local function chat_file_for_buf(bufnr)
    if file_by_buf[bufnr] then
      return file_by_buf[bufnr]
    end

    local root = roots_by_buf[bufnr]
    if not root then
      local context_path = current_context_path()
      root = project_root_from_path(context_path)
      roots_by_buf[bufnr] = root
    end

    local chats_dir = vim.fs.joinpath(root, ".chats")
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
      local context_path = current_context_path()
      roots_by_buf[bufnr] = project_root_from_path(context_path)
      chat_file_for_buf(bufnr)
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionChatDone",
    callback = function(ev)
      local bufnr = ev.data and ev.data.bufnr or nil
      save_chat_buffer(bufnr)
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionChatClosed",
    callback = function(ev)
      local bufnr = ev.data and ev.data.bufnr or nil
      save_chat_buffer(bufnr)
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
