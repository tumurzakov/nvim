local fmt = string.format

local PYTHON_CMD = "python3"
local CONTEXT_SRC = os.getenv("HOME") .. "/sources/context/src"

---@class CodeCompanion.Tool.EmailFetch: CodeCompanion.Tools.Tool
return {
  name = "email_fetch",
  cmds = {
    function(self, args)
      local date_str = args.date_str or os.date("%Y-%m-%d")
      local cmd = fmt(
        "%s -c \"import sys; sys.path.insert(0,'%s'); from fetch_emails import fetch_emails; from datetime import datetime; "
          .. "d=datetime.strptime('%s','%%Y-%%m-%%d').date(); emails=fetch_emails(d); "
          .. "parts=['From: '+e['from']+'\\nSubject: '+e['subject']+'\\nDate: '+e['date']+'\\nBody:\\n'+e['body'] for e in emails]; "
          .. "print('\\n---\\n'.join(parts) if parts else 'No emails found for %s.')\"",
        PYTHON_CMD,
        CONTEXT_SRC,
        date_str,
        date_str
      )
      local output = vim.fn.system(cmd)
      if vim.v.shell_error ~= 0 then
        return { status = "error", data = fmt("Error fetching emails: %s", output) }
      end
      return { status = "success", data = output }
    end,
  },
  schema = {
    type = "function",
    ["function"] = {
      name = "email_fetch",
      description = "Fetch emails from Mail.app for a given date. Returns sender, subject, date and body for each email.",
      parameters = {
        type = "object",
        properties = {
          date_str = {
            type = "string",
            description = "The date to fetch emails for in YYYY-MM-DD format. Defaults to today.",
          },
        },
      },
    },
  },
  output = {
    prompt = function(self)
      local date_str = self.args.date_str or os.date("%Y-%m-%d")
      return fmt("Fetch emails for %s?", date_str)
    end,
    success = function(self, tools, cmd, stdout)
      local chat = tools.chat
      local output = vim.iter(stdout):flatten():join("\n")
      local date_str = self.args.date_str or os.date("%Y-%m-%d")
      chat:add_tool_output(self, output, fmt("Fetched emails for %s", date_str))
    end,
    error = function(self, tools, cmd, stderr)
      local chat = tools.chat
      local errors = vim.iter(stderr):flatten():join("\n")
      chat:add_tool_output(self, fmt("Error fetching emails:\n%s", errors))
    end,
  },
}
