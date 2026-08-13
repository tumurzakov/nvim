---@class CodeCompanion.Tool.TeamsCalendar: CodeCompanion.Tools.Tool
return require("tools.context_tool").make({
  name = "teams_calendar",
  description = "Fetch Microsoft Teams calendar month view. Returns upcoming meetings, events and scheduled items.",
  code = function()
    return "from fetch_teams import fetch_teams_calendar; print(fetch_teams_calendar() or 'No calendar found.')"
  end,
  prompt = function() return "Fetch Teams calendar?" end,
  label = function() return "Fetched Teams calendar" end,
  err_prefix = "Error fetching Teams calendar",
})
