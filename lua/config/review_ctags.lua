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

-- (Re)generate `tags_file` for `root`, asynchronously. Absolute paths
-- (--tag-relative=never) so tag lookups resolve from any buffer/cwd. Silent no-op
-- if Universal Ctags isn't installed — tag jumps just won't resolve.
function M.ensure(root, tags_file, force)
  if not root or not tags_file then return end
  local ctags = M.bin()
  if not ctags then return end
  if not force and vim.fn.filereadable(tags_file) == 1 then return end
  -- ctags refuses to overwrite a target that "doesn't look like a tag file" — e.g.
  -- an empty/garbage file left by an interrupted or killed run. We always regenerate,
  -- so remove any existing target first; ctags then writes a fresh file with no refusal.
  vim.fn.delete(tags_file)
  vim.system({ ctags, "-R", "--tag-relative=never", "--fields=+n", "--exclude=.git",
    "-f", tags_file, root }, { text = true }, vim.schedule_wrap(function(res)
    if res.code ~= 0 then
      vim.notify("review_view: ctags failed: " .. (res.stderr or ""), vim.log.levels.WARN)
    end
  end))
end

return M
