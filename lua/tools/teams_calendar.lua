local fmt = string.format

local PYTHON_CMD = "python3"
local CONTEXT_SRC = os.getenv("HOME") .. "/sources/context/src"

---@class CodeCompanion.Tool.TeamsCalendar: CodeCompanion.Tools.Tool
return {
  name = "teams_calendar",
  cmds = {
    function(self, args)
      local cmd = fmt(
        "%s -c \"import sys; sys.path.insert(0,'%s'); from fetch_teams import fetch_teams_calendar; print(fetch_teams_calendar() or 'No calendar found.')\"",
        PYTHON_CMD,
        CONTEXT_SRC
      )
      local output = vim.fn.system(cmd)
      if vim.v.shell_error ~= 0 then
        return { status = "error", data = fmt("Error fetching Teams calendar: %s", output) }
      end
      return { status = "success", data = output }
    end,
  },
  schema = {
    type = "function",
    ["function"] = {
      name = "teams_calendar",
      description = "Fetch Microsoft Teams calendar month view. Returns upcoming meetings, events and scheduled items.",
      parameters = {
        type = "object",
        properties = {},
      },
    },
  },
  output = {
    prompt = function(self)
      return "Fetch Teams calendar?"
    end,
    success = function(self, tools, cmd, stdout)
      local chat = tools.chat
      local output = vim.iter(stdout):flatten():join("\n")
      chat:add_tool_output(self, output, "Fetched Teams calendar")
    end,
    error = function(self, tools, cmd, stderr)
      local chat = tools.chat
      local errors = vim.iter(stderr):flatten():join("\n")
      chat:add_tool_output(self, fmt("Error fetching Teams calendar:\n%s", errors))
    end,
  },
}
