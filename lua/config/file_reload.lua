-- Reload buffers changed on disk, so the LSP never serves a stale file.
--
-- Neovim refuses to advertise workspace/didChangeWatchedFiles on Linux and BSD
-- (runtime/lua/vim/lsp/protocol.lua: "all the current backends are too
-- limited"). A server therefore learns about an edit ONLY through didChange,
-- i.e. only for files this Neovim has in a buffer and knows are stale.
--
-- That is how gopls ends up reporting a type error against a definition that
-- was refactored two days ago: an agent or a git checkout rewrites the file,
-- the buffer keeps the old text, and :LspRestart makes it worse rather than
-- better — the restart replays didOpen with the SAME stale buffer content.
--
-- 'autoread' already reloads such a buffer, but only when :checktime runs, and
-- Neovim runs it on focus changes. Edits made by an agent in a split terminal
-- move no focus at all, so the check never fires. Hence CursorHold below.
--
-- Not solved by watching the tree instead: the enclosing repo here is a
-- monorepo whose app/ subtree alone is ~14k directories, and Neovim's Linux
-- fallback watcher re-walks what it watches on a timer.

local M = {}

-- Throttle: CursorHold fires every 'updatetime' (300ms here) and :checktime
-- stats every loaded buffer. Once a second is prompt enough for a human.
local interval_ms = 1000
local last = nil ---@type integer? -- nil until the first check; uv.now() is small right after startup, so 0 would swallow it

local function checkable()
  -- Only real files. Terminals, prompts and the cmdline window have nothing on
  -- disk to compare against, and :checktime in the cmdline window errors (E11).
  return vim.bo.buftype == "" and vim.fn.getcmdwintype() == "" and vim.fn.expand("%") ~= ""
end

local function check()
  if not checkable() then
    return
  end
  local now = vim.uv.now()
  if last and now - last < interval_ms then
    return
  end
  last = now
  -- Scheduled, not immediate: :checktime called from inside an autocommand
  -- reports success and reloads nothing, because a reload is not safe while an
  -- autocommand is running. Running it from the main loop actually reloads.
  --
  -- No argument: check every buffer, not just this one. A stale file feeding
  -- the LSP is usually one you are NOT looking at.
  vim.schedule(function()
    pcall(vim.cmd, "checktime")
  end)
end

function M.setup()
  vim.o.autoread = true

  local group = vim.api.nvim_create_augroup("user.file_reload", { clear = true })

  vim.api.nvim_create_autocmd(
    { "FocusGained", "BufEnter", "CursorHold", "CursorHoldI", "TermLeave" },
    { group = group, callback = check }
  )

  -- Say what happened. A buffer whose text changes under the cursor with no
  -- word about it reads as corruption.
  vim.api.nvim_create_autocmd("FileChangedShellPost", {
    group = group,
    callback = function(args)
      vim.notify(
        "reloaded from disk: " .. vim.fn.fnamemodify(args.file, ":~:."),
        vim.log.levels.INFO
      )
    end,
  })
end

-- Hard resync for the case the drip-feed above cannot cover: a file that no
-- buffer holds. Reload every buffer FIRST, then restart the servers, so the
-- didOpen that follows the restart carries the current text rather than
-- replaying the stale text that caused the restart.
function M.resync()
  last = nil -- an explicit ask must never hit the throttle
  vim.schedule(function()
    pcall(vim.cmd, "checktime")
    -- A tick later: the reload above must have sent its didChange before the
    -- server dies, or the restart replays the very text we just replaced.
    vim.schedule(function()
      pcall(vim.cmd, "LspRestart")
      vim.notify("buffers rechecked, LSP restarted", vim.log.levels.INFO)
    end)
  end)
end

return M
