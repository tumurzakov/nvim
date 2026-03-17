local M = {}

local fmt = string.format
local PYTHON_CMD = "python3"
local CONTEXT_SRC = os.getenv("HOME") .. "/sources/context/src"
local CONTEXT_DIR = os.getenv("HOME") .. "/sources/context"

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

local function write_file(path, content)
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")
  local f = io.open(path, "w")
  if not f then return false end
  f:write(content)
  f:close()
  return true
end

local function fetch_python(code)
  local cmd = fmt('%s -c "%s"', PYTHON_CMD, code)
  local output = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return "Fetch failed: " .. (output or "unknown error")
  end
  return output
end

local function add_section(parts, name, content)
  if content and not content:match("^%s*$") and not content:match("^Fetch failed") then
    table.insert(parts, fmt("## %s\n\n%s", name, content))
  end
end

function M.build(date_str)
  date_str = date_str or os.date("%Y-%m-%d")
  vim.notify(fmt("[Agenda] Fetching data for %s...", date_str), vim.log.levels.INFO)

  local parts = { fmt("# Raw Context (%s)", date_str) }

  -- 1. Emails
  vim.notify("[Agenda] Fetching emails...", vim.log.levels.INFO)
  vim.cmd("redraw")
  local emails = fetch_python(fmt(
    "import sys; sys.path.insert(0,'%s'); from fetch_emails import fetch_emails; from datetime import datetime; "
      .. "d=datetime.strptime('%s','%%Y-%%m-%%d').date(); emails=fetch_emails(d); "
      .. "parts=['From: '+e['from']+'\\nSubject: '+e['subject']+'\\nDate: '+e['date']+'\\nBody:\\n'+e['body'] for e in emails]; "
      .. "print('\\n---\\n'.join(parts) if parts else 'No emails found.')",
    CONTEXT_SRC, date_str
  ))
  add_section(parts, "Emails", emails)

  -- 2. Teams activity
  vim.notify("[Agenda] Fetching Teams activity...", vim.log.levels.INFO)
  vim.cmd("redraw")
  local activity = fetch_python(fmt(
    "import sys; sys.path.insert(0,'%s'); from fetch_teams import fetch_teams_activity; print(fetch_teams_activity() or 'No activity.')",
    CONTEXT_SRC
  ))
  add_section(parts, "Teams Activity", activity)

  -- 3. Teams chats
  vim.notify("[Agenda] Fetching Teams chats...", vim.log.levels.INFO)
  vim.cmd("redraw")
  local chats = fetch_python(fmt(
    "import sys; sys.path.insert(0,'%s'); from fetch_teams import fetch_teams_chats; print(fetch_teams_chats(5) or 'No chats.')",
    CONTEXT_SRC
  ))
  add_section(parts, "Teams Chats", chats)

  -- 4. Calendar
  vim.notify("[Agenda] Fetching calendar...", vim.log.levels.INFO)
  vim.cmd("redraw")
  local calendar = fetch_python(fmt(
    "import sys; sys.path.insert(0,'%s'); from fetch_teams import fetch_teams_calendar; print(fetch_teams_calendar() or 'No calendar.')",
    CONTEXT_SRC
  ))
  add_section(parts, "Teams Calendar", calendar)

  -- 5. Courses (click "See All" in Trainee block)
  vim.notify("[Agenda] Fetching courses...", vim.log.levels.INFO)
  vim.cmd("redraw")
  local courses_cmd = fmt("%s %s/fetch_courses_cli.py 2>&1", PYTHON_CMD, CONTEXT_SRC)
  local courses = vim.fn.system(courses_cmd)
  local courses_exit = vim.v.shell_error
  vim.notify(fmt("[Agenda] Courses exit=%d len=%d preview=%s", courses_exit, #(courses or ""), (courses or ""):sub(1, 120)), vim.log.levels.INFO)
  vim.cmd("redraw")
  if courses_exit ~= 0 then
    courses = "Fetch failed: " .. (courses or "unknown error")
  end
  add_section(parts, "Passed Courses", courses)

  -- 6. Web pages
  local web_pages = {
    { "Performance Portal", "https://example.com/telescope/profile?p=%2Fembedded%2Fpeople%2Fprofile%2FREDACTED_ID%2Fperformance" },
    { "Workplace", "https://example.com/workplace" },
    { "Learning", "https://learning.example.com/myLearning/overview" },
    { "Applications", "https://example.com/opportunities/positions/applications" },
  }
  for _, page in ipairs(web_pages) do
    local name, url = page[1], page[2]
    vim.notify(fmt("[Agenda] Fetching %s...", name), vim.log.levels.INFO)
    vim.cmd("redraw")
    local content = fetch_python(fmt(
      "import sys; sys.path.insert(0,'%s'); from fetch_web import fetch_page_text; print(fetch_page_text('%s') or 'Failed.')",
      CONTEXT_SRC, url
    ))
    add_section(parts, name, content)
  end

  -- 6. Local context files
  local context_files = {
    { "Backlog", CONTEXT_DIR .. "/backlog.md" },
    { "English Plan", CONTEXT_DIR .. "/english.md" },
  }
  for _, cf in ipairs(context_files) do
    local content = read_file(cf[2])
    add_section(parts, cf[1], content)
  end

  local output_path = fmt("%s/agenda/%s.md", CONTEXT_DIR, date_str)
  local content = table.concat(parts, "\n\n")

  if write_file(output_path, content) then
    vim.notify(fmt("[Agenda] Saved to %s", output_path), vim.log.levels.INFO)
    vim.cmd("edit " .. vim.fn.fnameescape(output_path))
  else
    vim.notify(fmt("[Agenda] Failed to write %s", output_path), vim.log.levels.ERROR)
  end
end

function M.setup()
  vim.api.nvim_create_user_command("Agenda", function(opts)
    local date_str = opts.args ~= "" and opts.args or nil
    M.build(date_str)
  end, {
    nargs = "?",
    desc = "Fetch all context sources and save raw data to agenda/YYYY-MM-DD.md",
  })
end

return M
