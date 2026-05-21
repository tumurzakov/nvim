local fmt = string.format

local PYTHON_CMD = "python3"
local CONTEXT_SRC = os.getenv("HOME") .. "/sources/context/src"

---@class CodeCompanion.Tool.TeamsChats: CodeCompanion.Tools.Tool
return {
  name = "teams_chats",
  cmds = {
    function(self, args)
      local n = args.n or 5
      local cmd = fmt(
        "%s -c \"import sys; sys.path.insert(0,'%s'); from fetch_teams import fetch_teams_chats; print(fetch_teams_chats(%d) or 'No chats found.')\"",
        PYTHON_CMD,
        CONTEXT_SRC,
        n
      )
      local output = vim.fn.system(cmd)
      if vim.v.shell_error ~= 0 then
        return { status = "error", data = fmt("Error fetching Teams chats: %s", output) }
      end
      return { status = "success", data = output }
    end,
  },
  schema = {
    type = "function",
    ["function"] = {
      name = "teams_chats",
      description = "Fetch the last N Microsoft Teams chat conversations with their messages. Defaults to 5 chats.",
      parameters = {
        type = "object",
        properties = {
          n = {
            type = "number",
            description = "Number of recent chats to fetch. Defaults to 5.",
          },
        },
      },
    },
  },
  output = {
    prompt = function(self)
      local n = self.args.n or 5
      return fmt("Fetch last %d Teams chats?", n)
    end,
    success = function(self, tools, cmd, stdout)
      local chat = tools.chat
      local output = vim.iter(stdout):flatten():join("\n")
      local n = self.args.n or 5
      chat:add_tool_output(self, output, fmt("Fetched last %d Teams chats", n))
    end,
    error = function(self, tools, cmd, stderr)
      local chat = tools.chat
      local errors = vim.iter(stderr):flatten():join("\n")
      chat:add_tool_output(self, fmt("Error fetching Teams chats:\n%s", errors))
    end,
  },
}
