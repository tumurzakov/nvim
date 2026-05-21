local fmt = string.format

local PYTHON_CMD = "python3"
local CONTEXT_SRC = os.getenv("HOME") .. "/sources/context/src"
local CONTEXT_DIR = os.getenv("HOME") .. "/sources/context"
local SKILLS_DIR = CONTEXT_DIR .. "/skills"

local ok_sl, settings_local = pcall(require, "config.settings_local")
local AGENDA_CFG = ok_sl and (settings_local.agenda or {}) or {}

--- Read a file and return its content or nil
local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

--- Run a python fetch command and return output
local function fetch_via_python(code)
  local cmd = fmt("%s -c \"%s\"", PYTHON_CMD, code)
  local output = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, output
  end
  return output
end

---@class CodeCompanion.Tool.BuildAgenda: CodeCompanion.Tools.Tool
return {
  name = "agenda",
  cmds = {
    function(self, args)
      local date_str = args.date_str or os.date("%Y-%m-%d")
      local parts = {}

      -- 1. Fetch emails
      local email_code = fmt(
        "import sys; sys.path.insert(0,'%s'); from fetch_emails import fetch_emails; from datetime import datetime; "
          .. "d=datetime.strptime('%s','%%Y-%%m-%%d').date(); emails=fetch_emails(d); "
          .. "parts=['From: '+e['from']+'\\nSubject: '+e['subject']+'\\nDate: '+e['date']+'\\nBody:\\n'+e['body'] for e in emails]; "
          .. "print('\\n---\\n'.join(parts) if parts else 'No emails found.')",
        CONTEXT_SRC,
        date_str
      )
      local emails = fetch_via_python(email_code)
      table.insert(parts, fmt("## Raw Emails (%s)\n\n%s", date_str, emails or "Failed to fetch emails."))

      -- 2. Fetch Teams activity
      local activity_code = fmt(
        "import sys; sys.path.insert(0,'%s'); from fetch_teams import fetch_teams_activity; print(fetch_teams_activity() or 'No activity found.')",
        CONTEXT_SRC
      )
      local activity = fetch_via_python(activity_code)
      table.insert(parts, fmt("## Raw Teams Activity\n\n%s", activity or "Failed to fetch Teams activity."))

      -- 3. Fetch Teams chats
      local chats_code = fmt(
        "import sys; sys.path.insert(0,'%s'); from fetch_teams import fetch_teams_chats; print(fetch_teams_chats(5) or 'No chats found.')",
        CONTEXT_SRC
      )
      local chats = fetch_via_python(chats_code)
      table.insert(parts, fmt("## Raw Teams Chats\n\n%s", chats or "Failed to fetch Teams chats."))

      -- 4. Fetch Teams calendar
      local calendar_code = fmt(
        "import sys; sys.path.insert(0,'%s'); from fetch_teams import fetch_teams_calendar; print(fetch_teams_calendar() or 'No calendar found.')",
        CONTEXT_SRC
      )
      local calendar = fetch_via_python(calendar_code)
      table.insert(parts, fmt("## Raw Teams Calendar\n\n%s", calendar or "Failed to fetch Teams calendar."))

      -- 5. Fetch web pages (configured in settings_local.agenda.web_pages)
      local web_pages = {}
      for _, entry in ipairs(AGENDA_CFG.web_pages or {}) do
        table.insert(web_pages, { name = entry[1], url = entry[2] })
      end
      for _, page in ipairs(web_pages) do
        local web_code = fmt(
          "import sys; sys.path.insert(0,'%s'); from fetch_web import fetch_page_text; print(fetch_page_text('%s') or 'Failed to fetch.')",
          CONTEXT_SRC,
          page.url
        )
        local web_content = fetch_via_python(web_code)
        table.insert(parts, fmt("## Raw %s\n\n%s", page.name, web_content or "Failed to fetch " .. page.name .. "."))
      end

      -- 5. Read existing context files
      local context_files = {
        { name = "Existing auto_tasks", path = fmt("%s/auto_tasks/%s.md", CONTEXT_DIR, date_str) },
        { name = "Backlog", path = CONTEXT_DIR .. "/backlog.md" },
        { name = "English Plan", path = CONTEXT_DIR .. "/english.md" },
        { name = "Applications", path = CONTEXT_DIR .. "/applications.md" },
      }
      for _, cf in ipairs(context_files) do
        local content = read_file(cf.path)
        if content then
          table.insert(parts, fmt("## %s\n\n%s", cf.name, content))
        end
      end

      -- 6. Read the agenda-builder skill instructions
      local skill_md = read_file(SKILLS_DIR .. "/agenda-builder/SKILL.md")
      if skill_md then
        table.insert(parts, fmt("## Skill Instructions\n\n%s", skill_md))
      end

      -- 7. Read the email-task-extractor skill for extraction rules
      local email_skill = read_file(SKILLS_DIR .. "/email-task-extractor/SKILL.md")
      if email_skill then
        table.insert(parts, fmt("## Email Task Extraction Rules\n\n%s", email_skill))
      end

      local full_context = table.concat(parts, "\n\n---\n\n")

      local instructions = fmt(
        [[I have fetched all raw data sources for %s. Using this data:

1. First, extract actionable tasks from each source (emails, teams activity, teams chats, web pages) following the extraction rules.
2. Then build a complete agenda.md following the Skill Instructions format.
3. Output the final agenda.md content.

The target date is %s.]],
        date_str,
        date_str
      )

      return {
        status = "success",
        data = instructions .. "\n\n" .. full_context,
      }
    end,
  },
  schema = {
    type = "function",
    ["function"] = {
      name = "agenda",
      description = "Fetch all context sources (emails, Teams activity, Teams chats, web portals) and build a daily agenda.",
      parameters = {
        type = "object",
        properties = {
          date_str = {
            type = "string",
            description = "Target date in YYYY-MM-DD format. Defaults to today.",
          },
        },
      },
    },
  },
  system_prompt = [[# Agenda Builder Tool

You have access to the `agenda` tool. When the user asks to build an agenda, create a daily summary, or asks about today's priorities:

1. Call `agenda` with the target date (or omit date_str for today).
2. The tool will fetch ALL data sources automatically (emails, Teams activity, Teams chats, web portals, existing task files).
3. Using the returned raw data and skill instructions, extract actionable tasks and produce a complete `agenda.md`.

IMPORTANT: You MUST call `agenda` first. Do NOT try to call individual fetch tools or make up data.]],
  output = {
    prompt = function(self)
      local date_str = self.args.date_str or os.date("%Y-%m-%d")
      return fmt("Build agenda for %s? (This will fetch emails, Teams, and web data)", date_str)
    end,
    success = function(self, tools, cmd, stdout)
      local chat = tools.chat
      local output = vim.iter(stdout):flatten():join("\n")
      local date_str = self.args.date_str or os.date("%Y-%m-%d")
      chat:add_tool_output(self, output, fmt("Fetched all context for agenda (%s)", date_str))
    end,
    error = function(self, tools, cmd, stderr)
      local chat = tools.chat
      local errors = vim.iter(stderr):flatten():join("\n")
      chat:add_tool_output(self, fmt("Error building agenda:\n%s", errors))
    end,
  },
}
