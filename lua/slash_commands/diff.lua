local config = require("codecompanion.config")
local log = require("codecompanion.utils.log")
local utils = require("codecompanion.utils")
local rc = require("config.review_context")

local fmt = string.format

local function build_message()
  local ctx = rc.diffview() or rc.fallback()
  if not ctx then return nil, "Not inside a git repo" end

  local diff, err = rc.diff(ctx.root, ctx.left_sha, ctx.right_sha, ctx.file, { right_is_local = ctx.right_is_local })
  if err then return nil, err end
  if not diff or diff == "" then
    return nil, fmt("No diff in %s..%s%s",
      ctx.left_display, ctx.right_display,
      ctx.file and (" for " .. ctx.file) or "")
  end

  local repo = rc.repo_name(ctx.root)
  local subjects = rc.commit_subjects(ctx.root, ctx.left_sha, ctx.right_sha)
  local subjects_block = rc.format_subjects(subjects)

  local parts = {
    fmt("Branch review: `%s` vs `%s` in repo `%s`.",
      ctx.right_display, ctx.left_display, repo),
  }
  if subjects_block then
    table.insert(parts, "")
    table.insert(parts, fmt("Commits in this range (%d):", #subjects))
    table.insert(parts, subjects_block)
  end
  table.insert(parts, "")
  if ctx.file then
    table.insert(parts, fmt("File: `%s`", ctx.file))
  else
    table.insert(parts, "Scope: whole repo")
  end
  table.insert(parts, "")
  table.insert(parts, "```diff")
  table.insert(parts, diff)
  table.insert(parts, "```")

  local header = fmt("Diff %s..%s%s",
    ctx.left_display, ctx.right_display,
    ctx.file and (" -- " .. ctx.file) or "")

  return header, table.concat(parts, "\n")
end

---@class CodeCompanion.SlashCommand.Diff: CodeCompanion.SlashCommand
local SlashCommand = {}

function SlashCommand.new(args)
  return setmetatable({
    Chat = args.Chat,
    config = args.config,
    context = args.context,
    opts = args.opts,
  }, { __index = SlashCommand })
end

function SlashCommand:execute()
  local header, body = build_message()
  if not header then
    return log:warn(body)
  end

  local id = "<diff>" .. header .. "</diff>"

  self.Chat:add_message({
    role = config.constants.USER_ROLE,
    content = body,
  }, {
    visible = false,
    context = { id = id },
    _meta = { tag = "diff" },
  })

  utils.notify(fmt("Added %s to the conversation", header))
end

return SlashCommand
