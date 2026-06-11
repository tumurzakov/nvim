-- agent_runner: spawn an external process and stream its stdout line-by-line.
-- Used by config/review_view.lua to run review "checkers" (AI agents or linters)
-- that print `LOC: <file>:<line> <msg>` lines. Mirrors the CLAUDECODE="" fix and
-- partial-line buffering from config/diff_review.lua.
local M = {}

-- M.run_cmd(cmd, opts)
--   cmd                argv table (e.g. { "claude", "-p" })
--   opts.env           table merged over the parent environment
--   opts.stdin         string piped to the process (channel closed after); nil = none
--   opts.on_line(line) called once per complete stdout line
--   opts.on_exit(code, stderr)  called when the job exits (stderr is a string)
--   opts.label         short scope name for heartbeat notifications
-- Returns the job id (>0) on success, or nil after notifying on failure.
function M.run_cmd(cmd, opts)
  opts = opts or {}
  local on_line = opts.on_line or function() end
  local on_exit = opts.on_exit or function() end

  if type(cmd) ~= "table" or not cmd[1] or cmd[1] == "" then
    vim.notify("agent_runner: invalid command", vim.log.levels.ERROR)
    return nil
  end

  local env = vim.tbl_extend("force", vim.fn.environ(), opts.env or {})

  local partial = ""
  local function process_lines(raw_lines)
    local lines = { partial .. (raw_lines[1] or "") }
    for i = 2, #raw_lines do table.insert(lines, raw_lines[i]) end
    partial = table.remove(lines) or ""
    for _, line in ipairs(lines) do on_line(line) end
  end

  local label = opts.label or "checker"
  local start_ms = vim.uv.now()
  local heartbeat = vim.uv.new_timer()
  heartbeat:start(5000, 5000, vim.schedule_wrap(function()
    local secs = math.floor((vim.uv.now() - start_ms) / 1000)
    vim.notify("checker: " .. label .. " (" .. secs .. "s)...", vim.log.levels.INFO)
  end))

  local stderr_buf = {}
  local job = vim.fn.jobstart(cmd, {
    env = env,
    stdout_buffered = false,
    on_stdout = function(_, data) process_lines(data) end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then table.insert(stderr_buf, line) end
      end
    end,
    on_exit = function(_, code)
      pcall(function() heartbeat:stop(); heartbeat:close() end)
      if partial ~= "" then on_line(partial); partial = "" end
      on_exit(code, table.concat(stderr_buf, "\n"))
    end,
  })

  if job <= 0 then
    pcall(function() heartbeat:stop(); heartbeat:close() end)
    vim.notify("agent_runner: failed to start " .. tostring(cmd[1]), vim.log.levels.ERROR)
    return nil
  end

  if opts.stdin and opts.stdin ~= "" then
    vim.fn.chansend(job, opts.stdin)
  end
  vim.fn.chanclose(job, "stdin")
  return job
end

return M
