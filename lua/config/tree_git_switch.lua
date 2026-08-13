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

local function remote_name()
  local ok, sl = pcall(require, "config.settings_local")
  return (ok and type(sl) == "table" and sl.git_remote) or "origin"
end

local function base_branch()
  local ok, sl = pcall(require, "config.settings_local")
  return (ok and type(sl) == "table" and sl.git_base_branch) or "main"
end

-- Branches sorted by most recent commit (stale ones sink to the end); a local
-- branch shadows its remote counterpart; the current branch is pinned on top.
local function branches(root)
  local cur
  local okc, c = git(root, { "symbolic-ref", "--quiet", "--short", "HEAD" })
  if okc and c[1] and c[1] ~= "" then cur = c[1] end

  local remote = remote_name()
  -- refs/heads sort before refs/remotes (alphabetical refname), so locals are
  -- seen first and win the dedup.
  local ok, refs = git(root, {
    "for-each-ref", "--format=%(refname)%09%(committerdate:unix)",
    "refs/heads", "refs/remotes/" .. remote,
  })
  local byname = {}
  if ok then
    for _, line in ipairs(refs) do
      local ref, date = line:match("^(.-)\t(%d+)$")
      date = tonumber(date) or 0
      local lname = ref and ref:match("^refs/heads/(.+)$")
      local rname = ref and ref:match("^refs/remotes/" .. remote .. "/(.+)$")
      if lname then
        byname[lname] = { name = lname, kind = "local", date = date }
      elseif rname and rname ~= "HEAD" and not byname[rname] then
        byname[rname] = { name = rname, kind = "remote", date = date }
      end
    end
  end

  local list = {}
  for _, v in pairs(byname) do list[#list + 1] = v end
  table.sort(list, function(a, b)
    if (a.name == cur) ~= (b.name == cur) then return a.name == cur end   -- current on top
    if a.date ~= b.date then return a.date > b.date end                   -- most recent first
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
    local name = vim.fn.fnamemodify(root, ":t")
    -- If the branch is remote-tracked, pull it up to the remote's latest
    -- (fast-forward only, so local commits are never discarded).
    local remote = remote_name()
    local tracked = git(root, { "rev-parse", "--verify", "--quiet", remote .. "/" .. b.name })
    if tracked then
      git(root, { "fetch", remote, b.name })
      local ff = git(root, { "merge", "--ff-only", remote .. "/" .. b.name })
      if ff then
        vim.notify(("git: %s → %s (up to date with %s)"):format(name, b.name, remote), vim.log.levels.INFO)
      else
        vim.notify(("git: %s → %s (diverged from %s — not pulled)"):format(name, b.name, remote),
          vim.log.levels.WARN)
      end
    else
      vim.notify(("git: %s → %s"):format(name, b.name), vim.log.levels.INFO)
    end
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

-- Freshen the local base branch (develop) from its remote WITHOUT switching to it.
-- `git fetch <remote> <base>:<base>` fast-forwards the local ref in place; it's
-- ff-only by default (a diverged base is rejected, nothing is forced). Handy from a
-- feature branch. If you're currently on the base branch git refuses this (can't
-- fetch into the checked-out branch) — use gp there instead.
function M.freshen_base(dir)
  local root = repo_root(dir)
  if not root then
    vim.notify("git: not a repository under " .. dir, vim.log.levels.WARN)
    return
  end
  local remote = remote_name()
  local base = base_branch()
  vim.notify(("git: freshening %s from %s/%s..."):format(base, remote, base), vim.log.levels.INFO)
  vim.system({ "git", "-C", root, "fetch", remote, base .. ":" .. base }, { text = true },
    function(res)
      vim.schedule(function()
        local err = vim.trim((res.stderr or "") .. (res.stdout or ""))
        if res.code == 0 then
          vim.notify(("git: %s is fresh (fast-forwarded from %s)"):format(base, remote), vim.log.levels.INFO)
        elseif err:match("Refusing to fetch into branch") or err:match("checked out") then
          vim.notify(("git: you're on %s — use gp to pull it instead"):format(base), vim.log.levels.WARN)
        elseif err:match("non%-fast%-forward") or err:match("rejected") then
          vim.notify(("git: local %s has diverged from %s/%s — not updated (rebase/reset manually)")
            :format(base, remote, base), vim.log.levels.WARN)
        else
          vim.notify("git: freshen failed:\n" .. err, vim.log.levels.ERROR)
        end
        pcall(function() require("nvim-tree.api").tree.reload() end)
      end)
    end)
end

-- Rebase the repo under `dir` onto the latest base (fetch <remote>/develop, then
-- git rebase). Clean → done; conflicts → roll back (abort) so nothing changes and
-- you resolve manually. Refuses on a detached HEAD.
function M.rebase(dir)
  local root = repo_root(dir)
  if not root then
    vim.notify("git: not a repository under " .. dir, vim.log.levels.WARN)
    return
  end
  local okc, c = git(root, { "symbolic-ref", "--quiet", "--short", "HEAD" })
  local branch = okc and c[1] or nil
  if not branch or branch == "" then
    vim.notify("git: HEAD is detached — cannot rebase", vim.log.levels.WARN)
    return
  end
  local remote = remote_name()
  local base = base_branch()
  local onto = remote .. "/" .. base
  if vim.fn.confirm(("Rebase '%s' onto latest %s?"):format(branch, onto), "&Yes\n&No", 2) ~= 1 then return end

  vim.notify(("git: fetching %s, rebasing %s onto %s..."):format(base, branch, onto), vim.log.levels.INFO)
  git(root, { "fetch", remote, base })
  vim.system({ "git", "-C", root, "rebase", onto }, { text = true }, function(res)
    vim.schedule(function()
      if res.code == 0 then
        vim.notify(("git: rebased %s onto %s"):format(branch, onto), vim.log.levels.INFO)
      else
        local err = vim.trim((res.stderr or "") .. (res.stdout or ""))
        local conflict = err:match("CONFLICT") or err:match("could not apply") or err:match("Resolve all conflicts")
        if conflict then
          git(root, { "rebase", "--abort" })
          vim.notify(("git: rebase onto %s has CONFLICTS — rolled back, nothing changed.\n"
            .. "Rebase manually to resolve:  git rebase %s"):format(onto, onto), vim.log.levels.WARN)
        else
          vim.notify("git: rebase failed:\n" .. err, vim.log.levels.ERROR)
        end
      end
      pcall(function() require("nvim-tree.api").tree.reload() end)
    end)
  end)
end

return M
