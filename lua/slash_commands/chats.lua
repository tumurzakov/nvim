local Path = require("plenary.path")
local config = require("codecompanion.config")
local log = require("codecompanion.utils.log")
local utils = require("codecompanion.utils")

local fmt = string.format

local CONSTANTS = {
  NAME = "Chats",
  PROMPT = "Select a saved chat",
}

local function chats_dir()
  local git_dir = vim.fs.find(".git", { path = vim.fn.getcwd(), upward = true })[1]
  local root = git_dir and vim.fs.dirname(git_dir) or vim.fn.getcwd()
  return vim.fs.joinpath(root, ".chats")
end

local function list_chat_files()
  local dir = chats_dir()
  if vim.fn.isdirectory(dir) == 0 then
    return {}
  end

  local files = vim.fn.glob(dir .. "/*.md", false, true)
  table.sort(files, function(a, b)
    return a > b
  end)
  return files
end

local function make_entries(files)
  local entries = {}
  for _, path in ipairs(files) do
    local name = vim.fn.fnamemodify(path, ":t")
    local f = io.open(path, "r")
    local preview = name
    if f then
      for _ = 1, 10 do
        local line = f:read("*l")
        if not line then
          break
        end
        local trimmed = vim.trim(line)
        if trimmed ~= "" and not trimmed:match("^#") and not trimmed:match("^%-%-%-") then
          preview = name .. " | " .. trimmed:sub(1, 80)
          break
        end
      end
      f:close()
    end
    table.insert(entries, { display = preview, path = path, name = name })
  end
  return entries
end

local providers = {
  telescope = function(SlashCommand)
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    local files = list_chat_files()
    if #files == 0 then
      utils.notify("No saved chats found in .chats/")
      return
    end

    local entries = make_entries(files)

    pickers.new({}, {
      prompt_title = CONSTANTS.PROMPT,
      finder = finders.new_table({
        results = entries,
        entry_maker = function(entry)
          return {
            value = entry,
            display = entry.display,
            ordinal = entry.name,
            path = entry.path,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            SlashCommand:output({ path = selection.value.path })
          end
        end)
        return true
      end,
    }):find()
  end,

  default = function(SlashCommand)
    local files = list_chat_files()
    if #files == 0 then
      utils.notify("No saved chats found in .chats/")
      return
    end

    local items = {}
    for _, path in ipairs(files) do
      table.insert(items, vim.fn.fnamemodify(path, ":t"))
    end

    vim.ui.select(items, { prompt = CONSTANTS.PROMPT }, function(choice)
      if not choice then
        return
      end
      local dir = chats_dir()
      SlashCommand:output({ path = vim.fs.joinpath(dir, choice) })
    end)
  end,
}

---@class CodeCompanion.SlashCommand.Chats: CodeCompanion.SlashCommand
local SlashCommand = {}

function SlashCommand.new(args)
  local self = setmetatable({
    Chat = args.Chat,
    config = args.config,
    context = args.context,
    opts = args.opts,
  }, { __index = SlashCommand })

  return self
end

function SlashCommand:execute(SlashCommands)
  return SlashCommands:set_provider(self, providers)
end

function SlashCommand:output(selected)
  local path = selected.path
  if not path then
    return
  end

  local ok, content = pcall(function()
    return Path.new(path):read()
  end)

  if not ok or not content or content == "" then
    return log:warn("Could not read chat file: %s", path)
  end

  local filename = vim.fn.fnamemodify(path, ":t")
  local id = "<chat_history>" .. filename .. "</chat_history>"

  local message = fmt(
    "Here is a previous chat conversation from `%s`:\n\n%s",
    filename,
    content
  )

  self.Chat:add_message({
    role = config.constants.USER_ROLE,
    content = message,
  }, {
    visible = false,
    context = { id = id, path = path },
    _meta = { tag = "file" },
  })

  utils.notify(fmt("Added chat `%s` to the conversation", filename))
end

return SlashCommand
