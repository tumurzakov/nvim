-- Pure diff parsing / line mapping helpers for the review view (gR).
-- No state: everything takes explicit arguments and returns plain tables.
local M = {}

-- Inverse of map_line: a diff-buffer row -> its source line (exact, else the
-- nearest mapped row above it, else 1). For untracked full-content buffers the
-- linemap is identity, so this returns the row unchanged.
function M.src_for_row(linemap, row)
  if not linemap then return row end
  local best_src, best_row
  for src, r in pairs(linemap) do
    if r == row then return src end
    if r <= row and (not best_row or r > best_row) then best_row, best_src = r, src end
  end
  return best_src or 1
end

-- Map a reported new-file line to a diff-buffer row (exact, else nearest <=, else 1).
function M.map_line(linemap, lnum)
  if linemap[lnum] then return linemap[lnum] end
  local best, best_row
  for nl, row in pairs(linemap) do
    if nl <= lnum and (not best or nl > best) then best, best_row = nl, row end
  end
  return best_row or 1
end

-- Annotate a unified diff with new-file line numbers (added/context lines get an
-- "N<TAB>" prefix) so an LLM checker copies the number instead of counting lines.
function M.numbered_diff(diff)
  local out, newln = {}, nil
  for _, line in ipairs(vim.split(diff, "\n", { plain = true })) do
    local h = line:match("^@@ %-%d+,?%d* %+(%d+)")
    if h then
      newln = tonumber(h); out[#out + 1] = line
    elseif newln and not line:match("^%+%+%+") and not line:match("^%-%-%-")
        and (line:sub(1, 1) == "+" or line:sub(1, 1) == " ") then
      out[#out + 1] = ("%d\t%s"):format(newln, line); newln = newln + 1
    else
      out[#out + 1] = line
    end
  end
  return table.concat(out, "\n")
end

-- Scan `git diff -U0 left [right] -- path` into hunks:
--   { nl, nc, removed = {lines}, adds = count }, nl/nc from the NEW side.
-- `right` nil ⇒ the working tree (live view); a commit sha ⇒ that checkpoint.
local function scan_hunks(root, left, right, path)
  local cmd = { "git", "-C", root, "diff", "-U0", left }
  if right then cmd[#cmd + 1] = right end
  vim.list_extend(cmd, { "--", path })
  local dl = vim.fn.systemlist(cmd)
  local hunks, i = {}, 1
  while i <= #dl do
    local nl, nc = dl[i]:match("^@@ %-%d+,?%d* %+(%d+),?(%d*) @@")
    if nl then
      nl, nc = tonumber(nl), (nc == "" and 1 or tonumber(nc))
      local removed, j, adds = {}, i + 1, 0
      while j <= #dl and not dl[j]:match("^@@") do
        local c = dl[j]:sub(1, 1)
        if c == "-" then removed[#removed + 1] = dl[j]:sub(2)
        elseif c == "+" then adds = adds + 1 end
        j = j + 1
      end
      hunks[#hunks + 1] = { nl = nl, nc = nc, removed = removed, adds = adds }
      i = j
    else
      i = i + 1
    end
  end
  return hunks
end

-- Classify per-line diff status of `path` between `left` and `right`:
--   added[n]=true (green), changed[n]=true (yellow)  — n is a line in the RIGHT side,
--   dels = { { line=n, above=bool, lines={removed text} } }  (red, shown as virt lines)
function M.diff_status(root, left, right, path)
  local added, changed, dels = {}, {}, {}
  for _, h in ipairs(scan_hunks(root, left, right, path)) do
    if #h.removed == 0 then
      for k = 0, h.nc - 1 do added[h.nl + k] = true end
    elseif h.nc == 0 then
      dels[#dels + 1] = { line = h.nl, above = false, lines = h.removed }   -- pure deletion
    else
      for k = 0, h.nc - 1 do changed[h.nl + k] = true end
      dels[#dels + 1] = { line = h.nl, above = true, lines = h.removed }    -- replacement
    end
  end
  return added, changed, dels
end

-- The left→right hunks for `path`, keeping each hunk's new-file range
-- (nl .. nl+nc-1) and its removed (base) lines, so a single change can be
-- reverted to its base state.
function M.parse_hunks(root, left, right, path)
  local hunks = {}
  for _, h in ipairs(scan_hunks(root, left, right, path)) do
    hunks[#hunks + 1] = { nl = h.nl, nc = h.nc, removed = h.removed }
  end
  return hunks
end

return M
