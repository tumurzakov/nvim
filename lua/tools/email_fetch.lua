local fmt = string.format

local function date_of(args)
  return args.date_str or os.date("%Y-%m-%d")
end

---@class CodeCompanion.Tool.EmailFetch: CodeCompanion.Tools.Tool
return require("tools.context_tool").make({
  name = "email_fetch",
  description = "Fetch emails from Mail.app for a given date. Returns sender, subject, date and body for each email.",
  properties = {
    date_str = {
      type = "string",
      description = "The date to fetch emails for in YYYY-MM-DD format. Defaults to today.",
    },
  },
  code = function(args)
    local d = date_of(args)
    return fmt(
      "from fetch_emails import fetch_emails; from datetime import datetime; "
        .. "d=datetime.strptime('%s','%%Y-%%m-%%d').date(); emails=fetch_emails(d); "
        .. "parts=['From: '+e['from']+'\\nSubject: '+e['subject']+'\\nDate: '+e['date']+'\\nBody:\\n'+e['body'] for e in emails]; "
        .. "print('\\n---\\n'.join(parts) if parts else 'No emails found for %s.')",
      d, d
    )
  end,
  prompt = function(args) return fmt("Fetch emails for %s?", date_of(args)) end,
  label = function(args) return fmt("Fetched emails for %s", date_of(args)) end,
  err_prefix = "Error fetching emails",
})
