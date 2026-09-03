-- Universal Ctags integration for the review view: locate the binary, decide
-- where a repo's tags file lives, and (re)generate it asynchronously.
local M = {}

-- Locate a Universal Ctags binary. On macOS /usr/bin/ctags (BSD) shadows the
-- Homebrew one in PATH, so probe explicit locations and verify the flavour.
local _ctags_bin
function M.bin()
  if _ctags_bin ~= nil then return _ctags_bin or nil end
  local cands = {
    "/opt/homebrew/bin/ctags", "/opt/homebrew/opt/universal-ctags/bin/ctags",
    "/usr/local/bin/ctags", "/usr/local/opt/universal-ctags/bin/ctags", "ctags",
  }
  for _, c in ipairs(cands) do
    if vim.fn.executable(c) == 1 then
      local v = vim.system({ c, "--version" }, { text = true }):wait()
      if v.code == 0 and (v.stdout or ""):match("Universal Ctags") then
        _ctags_bin = c; return c
      end
    end
  end
  _ctags_bin = false
  return nil
end

-- Where the repo's tags file lives (per-repo, in the cache dir).
function M.tags_path(root)
  local dir = vim.fn.stdpath("cache") .. "/review_view"
  vim.fn.mkdir(dir, "p")
  return dir .. "/" .. root:gsub("[^%w]", "_") .. ".tags"
end

-- Runs in flight, keyed by tags_file: { pending = bool }. Opening the review view
-- triggers several ensure(force) calls in a row; without this, a later run's delete
-- would unlink the file an earlier run is still writing, and that run's `sort -u -o
-- <file> <file>` would die with "sort: No such file or directory".
local running = {}

-- (Re)generate `tags_file` for `root`, asynchronously. Absolute paths
-- (--tag-relative=never) so tag lookups resolve from any buffer/cwd. Silent no-op
-- if Universal Ctags isn't installed — tag jumps just won't resolve.
function M.ensure(root, tags_file, force)
  if not root or not tags_file then return end
  local ctags = M.bin()
  if not ctags then return end
  if not force and vim.fn.filereadable(tags_file) == 1 then return end
  -- Already indexing this repo: remember that another rebuild was asked for and
  -- run it once the current one finishes, rather than racing it.
  if running[tags_file] then
    running[tags_file].pending = true
    return
  end
  running[tags_file] = { pending = false }

  -- Build into a scratch file and rename into place: ctags refuses to overwrite a
  -- target that "doesn't look like a tag file" (e.g. leftovers from a killed run),
  -- and the rename keeps `tags_file` readable and complete the whole time.
  -- Pid-scoped so a second Neovim reviewing the same repo can't clobber this run
  -- either (the tags path is derived from the repo root, so it is shared).
  local tmp = ("%s.%d.building"):format(tags_file, vim.uv.os_getpid())
  vim.fn.delete(tmp)
  -- --quiet drops the "Notice: ignoring null tag in ..." spam that minified JS in
  -- vendored/.venv trees emits by the hundreds — it would otherwise land in the
  -- failure notify below and paper over the whole screen.
  vim.system({ ctags, "-R", "--quiet", "--tag-relative=never", "--fields=+n", "--exclude=.git",
    "-f", tmp, root }, { text = true }, vim.schedule_wrap(function(res)
    local again = running[tags_file] and running[tags_file].pending
    running[tags_file] = nil
    if res.code == 0 then
      vim.uv.fs_rename(tmp, tags_file)
    else
      vim.fn.delete(tmp)
      -- Keep this to a single line that fits the command area: a multi-line or
      -- wrapping notify triggers the hit-enter prompt, and a failed background
      -- reindex isn't worth interrupting the review for.
      local first = vim.split(vim.trim(res.stderr or ""), "\n", { plain = true })[1]
      local msg = "review_view: ctags failed: " .. (first ~= "" and first or "exit " .. res.code)
      local maxw = math.max(40, vim.o.columns - 12)
      if vim.fn.strdisplaywidth(msg) > maxw then msg = msg:sub(1, maxw - 1) .. "…" end
      vim.notify(msg, vim.log.levels.WARN)
    end
    if again then M.ensure(root, tags_file, true) end
  end))
end

return M
