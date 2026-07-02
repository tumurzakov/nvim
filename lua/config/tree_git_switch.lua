-- Floating branch switcher for nvim-tree (gB). Lists the branches of the repo
-- for the folder under the cursor; selecting one checks it out and reloads the
-- tree so the inline branch label + git status refresh.
local M = {}

local function git(dir, args)
  local cmd = { "git", "-C", dir }
  vim.list_extend(cmd, args)
  local out = vim.fn.systemlist(cmd)
  return vim.v.shell_error == 0, out
end

local function repo_root(dir)
  local ok, out = git(dir, { "rev-parse", "--show-toplevel" })
  if ok and out[1] and out[1] ~= "" then return out[1] end
  return nil
end

-- Local branches first, then origin/* branches without a local counterpart.
local function branches(root)
  local cur
  local okc, c = git(root, { "symbolic-ref", "--quiet", "--short", "HEAD" })
  if okc and c[1] and c[1] ~= "" then cur = c[1] end

  local list, seen = {}, {}
  local okl, locals = git(root, { "for-each-ref", "--format=%(refname:short)", "refs/heads" })
  if okl then
    for _, b in ipairs(locals) do
      if b ~= "" then list[#list + 1] = { name = b, kind = "local" }; seen[b] = true end
    end
  end
  local okr, remotes = git(root, { "for-each-ref", "--format=%(refname:short)", "refs/remotes/origin" })
  if okr then
    for _, b in ipairs(remotes) do
      local short = b:gsub("^origin/", "")
      if b ~= "" and short ~= "HEAD" and not seen[short] then
        list[#list + 1] = { name = short, kind = "remote" }; seen[short] = true
      end
    end
  end

  table.sort(list, function(a, b)
    local ar = (a.name == cur) and 0 or (a.kind == "local" and 1 or 2)
    local br = (b.name == cur) and 0 or (b.kind == "local" and 1 or 2)
    if ar ~= br then return ar < br end
    return a.name < b.name
  end)
  return list, cur
end

function M.switch(dir)
  local root = repo_root(dir)
  if not root then
    vim.notify("git: not a repository under " .. dir, vim.log.levels.WARN)
    return
  end
  local list, cur = branches(root)
  if #list == 0 then
    vim.notify("git: no branches found", vim.log.levels.INFO)
    return
  end

  local lines = {}
  for i, b in ipairs(list) do
    local mark = (b.name == cur) and "* " or "  "
    local tag = b.kind == "remote" and "  (remote)" or ""
    lines[i] = string.format(" %s%s%s", mark, b.name, tag)
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false

  local title = " Switch branch — " .. vim.fn.fnamemodify(root, ":t") .. "  (Enter · / search · q) "
  local width = vim.fn.strdisplaywidth(title)
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l)) end
  width = math.min(width + 2, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 4)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })
  vim.wo[win].cursorline = true
  for i, b in ipairs(list) do
    if b.name == cur then pcall(vim.api.nvim_win_set_cursor, win, { i, 0 }); break end
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end

  local function choose(idx)
    local b = list[idx]
    if not b then return end
    close()
    if b.name == cur then return end
    local ok, out = git(root, { "checkout", b.name })
    if not ok then
      vim.notify("git checkout " .. b.name .. " failed:\n" .. table.concat(out, "\n"), vim.log.levels.ERROR)
      return
    end
    vim.notify(("git: %s → %s"):format(vim.fn.fnamemodify(root, ":t"), b.name), vim.log.levels.INFO)
    pcall(function() require("nvim-tree.api").tree.reload() end)
  end

  local function map(lhs, rhs)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true })
  end
  map("q", close)
  map("<Esc>", close)
  map("<CR>", function() choose(vim.api.nvim_win_get_cursor(win)[1]) end)
  for i = 1, math.min(#list, 9) do
    map(tostring(i), function() choose(i) end)
  end
end

return M
