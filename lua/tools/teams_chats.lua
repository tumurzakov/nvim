local fmt = string.format

---@class CodeCompanion.Tool.TeamsChats: CodeCompanion.Tools.Tool
return require("tools.context_tool").make({
  name = "teams_chats",
  description = "Fetch the last N Microsoft Teams chat conversations with their messages. Defaults to 5 chats.",
  properties = {
    n = {
      type = "number",
      description = "Number of recent chats to fetch. Defaults to 5.",
    },
  },
  code = function(args)
    return fmt("from fetch_teams import fetch_teams_chats; print(fetch_teams_chats(%d) or 'No chats found.')", args.n or 5)
  end,
  prompt = function(args) return fmt("Fetch last %d Teams chats?", args.n or 5) end,
  label = function(args) return fmt("Fetched last %d Teams chats", args.n or 5) end,
  err_prefix = "Error fetching Teams chats",
})
