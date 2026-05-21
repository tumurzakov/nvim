local fmt = string.format

local PYTHON_CMD = "python3"
local CONTEXT_SRC = os.getenv("HOME") .. "/sources/context/src"

---@class CodeCompanion.Tool.TeamsActivity: CodeCompanion.Tools.Tool
return {
  name = "teams_activity",
  cmds = {
    function(self, args)
      local cmd = fmt(
        "%s -c \"import sys; sys.path.insert(0,'%s'); from fetch_teams import fetch_teams_activity; print(fetch_teams_activity() or 'No activity found.')\"",
        PYTHON_CMD,
        CONTEXT_SRC
      )
      local output = vim.fn.system(cmd)
      if vim.v.shell_error ~= 0 then
        return { status = "error", data = fmt("Error fetching Teams activity: %s", output) }
      end
      return { status = "success", data = output }
    end,
  },
  schema = {
    type = "function",
    ["function"] = {
      name = "teams_activity",
      description = "Fetch Microsoft Teams activity feed. Returns recent notifications, mentions, and reactions from Teams.",
      parameters = {
        type = "object",
        properties = {},
      },
    },
  },
  output = {
    prompt = function(self)
      return "Fetch Teams activity feed?"
    end,
    success = function(self, tools, cmd, stdout)
      local chat = tools.chat
      local output = vim.iter(stdout):flatten():join("\n")
      chat:add_tool_output(self, output, "Fetched Teams activity feed")
    end,
    error = function(self, tools, cmd, stderr)
      local chat = tools.chat
      local errors = vim.iter(stderr):flatten():join("\n")
      chat:add_tool_output(self, fmt("Error fetching Teams activity:\n%s", errors))
    end,
  },
}
