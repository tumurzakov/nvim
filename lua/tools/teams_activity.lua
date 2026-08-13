---@class CodeCompanion.Tool.TeamsActivity: CodeCompanion.Tools.Tool
return require("tools.context_tool").make({
  name = "teams_activity",
  description = "Fetch Microsoft Teams activity feed. Returns recent notifications, mentions, and reactions from Teams.",
  code = function()
    return "from fetch_teams import fetch_teams_activity; print(fetch_teams_activity() or 'No activity found.')"
  end,
  prompt = function() return "Fetch Teams activity feed?" end,
  label = function() return "Fetched Teams activity feed" end,
  err_prefix = "Error fetching Teams activity",
})
