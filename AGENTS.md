## Global rules

- Never use markdown tables in any response.
- Never use pipe-separated rows (for example: `| col | val |`).
- Never use ASCII table layouts.
- If information is tabular, rewrite it as:
  - a flat bullet list, or
  - short labeled lines (`Field: value`).
- Keep formatting simple and readable in plain text.

## Context structure

The user's working context lives at `~/sources/context/`. Here is the layout:

- `agenda.md` — today's compiled agenda (output of agenda-builder skill)
- `agenda/YYYY-MM-DD.md` — daily agenda archive snapshots
- `auto_tasks/YYYY-MM-DD.md` — auto-extracted tasks per day (from email, Teams, workplace, etc.)
- `daily/YYYY-MM-DD.md` — personal daily notes, reflections, carry-over tasks, chat excerpts, decisions
- `chats/YYYY-MM-DD.md` — saved Teams chat extracts
- `backlog.md` — epics and longer-term tasks
- `english.md` — English learning plan, course deadlines, assessment status
- `cv.md` — CV / profile
- `skill_matrix.md` — skills and competencies
- `archive/` — older reference materials (profiles, presentations, etc.)
- `skills/` — automation skills (agenda-builder, email-task-extractor, fetch-* scrapers)
- `src/` — MCP server and fetch scripts (mcp_server.py, fetch_emails.py, fetch_teams.py, fetch_web.py)

### `daily/` folder

The `daily/` folder is critical for agenda building. Each file is a day's working journal and may contain:
- Notes from meetings and conversations
- Decisions made during the day
- Carry-over tasks that were not completed
- Blockers discovered
- Links, code snippets, or commands to remember
- Personal reflections

When building an agenda, always check `daily/` files from the last 3 days to find carry-over items, unfinished tasks, and context that should inform today's priorities.
