local M = {}

-- ─────────────────────────────────────────────────────────────────────────
-- Cheatsheet pages. Each entry: { name = "Tab label", text = [[ body ]] }
-- The Vim page also appends recent project files dynamically (see render()).
-- ─────────────────────────────────────────────────────────────────────────

local vim_text = [[
 Keybindings (Leader = \)

 FILES            LSP                  AI (CodeCompanion)
 \e   Explorer    gd  Definition       C-l  Chat / paste sel
 \tt  NvimTree    gr  References       C-k  Explain (hover)
 ±/~  Tree focus  gi  Implementation   A-l  Toggle chat
 \ff  Find files  K   Hover info       \ci  Rewrite (visual)
 \fg  Live grep   \rn Rename           \cc  Chat
 \fb  Buffers     \ca Code action      \cm  Commit message
 \fh  Help tags   \f  Format           \ca  Actions (visual)
 F9   Aerial                           \cq  Review Q (visual)
                                       /diff in chat: insert git diff

 TERMINAL (C-b prefix)                 PYTHON & TESTING
 C-b n/p  Next/prev tab                \ta  Pytest all
 C-b c    New tab                      \tf  Pytest file
 \rl      Run current line             \tn  Pytest nearest
 \r       Run selection (visual)       \rx  Ruff fix
 T        Tree: term here (keep tree)  \x   Run file
 \T       Tree: term here (focus term)

 WINDOW           SPEECH               WEB
 F3   Zoom split  F8   Read/stop      \ws  Summarize web page
                  \ss  Speak sel
                  \sq  Stop speaking

 GIT & REVIEW
 gR   Patch review (red/green; r=review e=edit ]q/[q=nav Tab=fold zM/zR=all)
 \gc  Close review view
 \kd  Drop sel/file:line → Claude kitty tab   \kf  Drop file path

 DIAGNOSTICS (Trouble)
 \xx  Workspace diagnostics            \xs  Symbols
 \xX  Buffer diagnostics               \xl  LSP refs/definitions
 \xQ  Quickfix list                    \xL  Location list
 [x / ]x  Prev / next item

 EDITING          COMPLETION (insert)  COMMANDS
 jk  Leave insert C-Space Trigger      :ReloadConfig
                  Enter   Confirm      :CC  CodeCompanion
                  C-e     Abort        :Agenda [date]
                                       :Cheatsheet]]

local vim_general_text = [[
 Vim — high-leverage moves

 TEXT OBJECTS                          DOT & REPEAT
 ciw  change inner word                .    repeat last change
 ci"  ci(  cit  change inside          ;  , repeat / reverse f F t T
 dap  delete a paragraph               &    repeat last :s on line
 dt)  ct,  till / to char              gv   reselect last visual
 yi{  vi[  yank / select inside        @@   repeat last macro

 MOTIONS                               CASE / NUMBERS
 f F t T  find char on line            gU gu g~  upper / lower / toggle
 %    jump to matching pair            C-a  C-x  increment / decrement
 { }  ( )  paragraph / sentence        g C-a    visual = make a sequence
 H M L  screen top / mid / bottom
 zt zz zb  cursor to top/center/bot    LINES
 *  #   search word under cursor       J   gJ   join (with / no space)
                                       ddp      swap two lines
 REGISTERS / MACROS                    :m +1    move line down
 "+y  "+p   system clipboard           >gv      indent, keep selection
 "0   last yank    "_d   black hole
 :reg  list registers                  VISUAL BLOCK
 qa … q   record macro → @a            C-v   block select
 3@a      play macro 3 times           I A   insert at block edges
 :%norm @a   run macro on every line   $     insert at ragged line-ends
                                       o     swap selection ends
 SUBSTITUTE / GLOBAL
 :%s/old/new/gc   confirm each   ·   :%s//new/g  reuse last pattern
 :s/\v(\w+)/[\1]/   very magic + capture group
 gn   cgn then .   change next match, then repeat with dot
 :g/pat/d     :v/pat/d     delete matching / non-matching lines
 :g/pat/normal A;          run a command on every matching line

 COMMAND-LINE / EX
 q:    command-line window — edit & re-run past commands
 C-r 0  paste yank reg   ·   C-r "  last delete   ·   C-r +  clipboard
 C-r C-w   pull word under cursor into  :  or  /
 :%!sort   filter buffer through a shell   ·   :r !date  read output
 :w ++p    write, creating missing parent dirs
 :verbose map \x   where is a key mapped   ·   ga  char codes here
 g- g+   :earlier 5m   walk undo history / undo branches

 WINDOWS / FILES                       GREP → QUICKFIX
 C-w s / C-w v   split horiz / vert    :grep -rn pat    grep → quickfix
 C-w h j k l     focus split           :vimgrep /pat/ **/*   vim's regex
 C-w w / C-w p   cycle / last split    :copen  :cclose  open / close qf
 C-w o           only (close others)   :cn  :cp         next / prev match
 C-w c / C-w q   close split           :cdo s/a/b/g | update  edit all
 C-^   (= C-6)   edit alternate file   :set grepprg=rg\ --vimgrep
 gf              open file under cursor]]

local code_text = [==[
 Code — LSP · refactor · Python · Terraform

 LSP / NAVIGATE                        DIAGNOSTICS
 gd  Definition   gr  References       [d  ]d   Prev / next problem
 gi  Implementation  K  Hover docs     gl       Show diagnostic float
 \rn Rename       \ca Code action      \xx \xX  Trouble work / buffer
 \f  Format buffer                     \xs      Symbols   ·   F9 Aerial
 C-s Signature help (insert mode)

 TREESITTER TEXT OBJECTS   (operator + object, e.g. daf  cif  vac)
 af if   a / inner function            ]m [m   Next / prev function
 ac ic   a / inner class               ]] [[   Next / prev class
 aa ia   a / inner argument            \na \pa Swap argument next / prev
 daf delete func · cif change body · vac select class · cia change arg

 SURROUND (ys add · ds delete · cs change)    PAIRS
 ysiw"   surround word with "          ds(    delete surrounding ( )
 yss)    surround whole line           cs"'   change  "  to  '
 S"      surround visual selection     ( [ { " '  auto-close in insert

 PYTHON                                TERRAFORM
 \ta  Pytest all in file               gd K \rn  go-to / hover / rename
 \tf  Pytest current file              \ca   code action
 \tn  Pytest nearest (cursor)          \f    fmt  (also runs on save)
 \rx  Ruff check --fix                 venv auto-detected (uv / poetry)
 \x   Run current file                 terraform-ls drives completion]==]

local console_text = [[
 Terminal navigation — bash / zsh (macOS & Linux)

 NAVIGATION                            EDITING
 C-a  Start of line                    C-d  Delete char under cursor
 C-e  End of line                      C-h  Delete char before (backspace)
 A-b  Back one word                    C-w  Delete word before cursor
 A-f  Forward one word                 A-d  Delete word after cursor
 C-b  Back one char                    C-u  Delete to start of line
 C-f  Forward one char                 C-k  Delete to end of line
                                       C-y  Paste (yank) last delete
 HISTORY                               C-t  Swap two chars before cursor
 C-r  Search history backward          C-_  Undo last edit
 C-s  Search history forward
 C-p / Up    Previous command          PROCESS CONTROL
 C-n / Down  Next command              C-c  Interrupt / kill process
 Enter  Run the found command          C-z  Suspend  (resume with: fg)
 C-g    Cancel C-r, keep typed text     C-d  EOF / exit shell
 A-.    Last arg of previous command    C-l  Clear screen
                                       C-s / C-q  Pause / resume output

 macOS: Alt = Option. Terminal.app → Profiles → Keyboard →
        ✓ "Use Option as Meta key"  (iTerm2 works out of the box).
 Tip: C-r then type any old command to find it instantly; C-r again cycles.]]

local kitty_text = [[
 Kitty terminal — default keys (kitty_mod = Ctrl+Shift)

 TABS                                  WINDOWS (splits)
 C-S-t    New tab                      C-S-↵    New window
 C-S-q    Close tab                    C-S-w    Close window
 C-S-→ ←  Next / prev tab              C-S-] [  Next / prev window
 C-S-. ,  Move tab right / left        C-S-f b  Move window fwd / back
 C-S-A-t  Set tab title                C-S-l    Next layout
 C-Tab    Cycle tabs                   C-S-r    Resize-window mode

 SCROLLBACK                            FONT SIZE
 C-S-↑ ↓        Scroll line            C-S-=    Increase
 C-S-PgUp/PgDn  Scroll page            C-S--    Decrease
 C-S-Home/End   Top / bottom           C-S-⌫    Reset size
 C-S-h     Open scrollback in pager
 C-S-z x   Prev / next shell prompt*   COPY / PASTE
                                       C-S-c    Copy
 MISC                                  C-S-v    Paste
 C-S-e     Open URL hints              C-S-u    Unicode input
 C-S-f5    Reload kitty.conf           C-S-Esc  Kitty command shell
 C-S-f11   Toggle fullscreen           C-S-Del  Clear / reset terminal

 * prompt jumps need shell integration (on by default in kitty).
 macOS also: ⌘T new tab · ⌘↵ fullscreen · ⌘+/− font · ⌘C/⌘V copy/paste.
 CLI: kitty @ ls  ·  kitty @ launch --type=tab  ·  kitten icat img.png]]

local aws_text = [[
 AWS CLI cheatsheet

 CONFIG & AUTH                         S3
 aws configure                         aws s3 ls
 aws configure --profile NAME          aws s3 ls s3://BUCKET
 aws configure sso                     aws s3 cp FILE s3://BUCKET/
 aws sts get-caller-identity           aws s3 sync DIR s3://BUCKET/
 export AWS_PROFILE=NAME               aws s3 rm s3://BUCKET/KEY
 export AWS_REGION=us-east-1           aws s3 presign s3://BUCKET/KEY

 EC2                                   LOGS / CLOUDWATCH
 aws ec2 describe-instances            aws logs tail GROUP --follow
 aws ec2 start-instances --instance-ids ID
 aws ec2 stop-instances  --instance-ids ID
 aws ec2 describe-security-groups      LAMBDA
                                       aws lambda list-functions
 ECR                                   aws lambda invoke \
 aws ecr describe-repositories           --function-name F out.json
 aws ecr get-login-password \
   | docker login --username AWS --password-stdin URL

 SSM / SECRETS                         GLOBAL FLAGS
 aws ssm start-session --target ID     --profile P   --region R
 aws secretsmanager get-secret-value \ --output table|json|text
   --secret-id NAME                    --query 'JMESPath-expr']]

local claude_text = [[
 Claude Code (CLI) cheatsheet

 SESSION                               SLASH COMMANDS
 claude            Start interactive   /clear   Reset conversation
 claude "prompt"   One-shot ask        /compact Summarize + free context
 claude -c         Continue last       /model   Switch model
 claude -r         Resume a session    /config  Open settings
 claude -p "..."   Print mode (pipe)   /init    Generate CLAUDE.md
 claude commit     Commit helper       /review  Review a PR

 IN-SESSION KEYS                       /agents  Manage subagents
 Esc        Interrupt Claude           /mcp     MCP servers
 Esc Esc    Edit previous message      /memory  Edit memory files
 Shift-Tab  Cycle permission modes     /cost    Token usage
 Ctrl-R     Verbose / expand output    /vim     Vim keybindings
 ! prefix   Run a bash command         /help    All commands
 # prefix   Add a memory               @path    Reference a file

 PROMPT BAR (text input — same readline keys as the Console tab)
 C-a / C-e   Line start / end          A-b / A-f   Word back / forward
 C-b / C-f   Char back / forward       C-w  del word  ·  C-u  clear line
 C-k         Delete to end of line     \ + Enter / Shift-Enter   newline
 ↑ / ↓       Recall past prompts (or move between lines when multiline)

 TIPS
 Enter Plan mode (Shift-Tab) to design before editing.
 Pipe data in:   cat file | claude -p "explain this"
 CLAUDE.md in the repo root = persistent project instructions.]]

local sheets = {
  { name = "Mine", text = vim_text },
  { name = "Vim", text = vim_general_text },
  { name = "Code", text = code_text },
  { name = "Console", text = console_text },
  { name = "Kitty", text = kitty_text },
  { name = "AWS", text = aws_text },
  { name = "Claude", text = claude_text },
}

local ns = vim.api.nvim_create_namespace("help_cheatsheet")

local state = { buf = nil, win = nil, idx = 1, recent = {}, cwd = nil, tab_ranges = {} }

-- Collect up to 3 recent project files (used only on the Vim page).
local function collect_recent()
  local cwd = vim.fn.getcwd()
  local recent = {}
  for _, f in ipairs(vim.v.oldfiles or {}) do
    if #recent >= 3 then break end
    if vim.startswith(f, cwd .. "/") and vim.fn.filereadable(f) == 1 then
      table.insert(recent, f:sub(#cwd + 2))
    end
  end
  state.cwd = cwd
  state.recent = recent
end

-- Build the tab-bar line and record byte ranges for click/highlight.
local function build_tabbar()
  local bar = " "
  state.tab_ranges = {}
  for i, s in ipairs(sheets) do
    local label = " " .. s.name .. " "
    local start_col = #bar
    bar = bar .. label
    table.insert(state.tab_ranges, { s = start_col, e = #bar, idx = i })
    bar = bar .. " "
  end
  return bar
end

local function content_lines()
  local lines = {}
  table.insert(lines, build_tabbar())
  table.insert(lines, " Tab/S-Tab or h/l switch · click a tab · q/Esc close")
  table.insert(lines, "")

  for _, l in ipairs(vim.split(sheets[state.idx].text, "\n")) do
    table.insert(lines, l)
  end

  if state.idx == 1 and #state.recent > 0 then
    table.insert(lines, "")
    table.insert(lines, " Recent files (project):")
    for i, f in ipairs(state.recent) do
      table.insert(lines, " " .. i .. ". " .. f)
    end
  end

  return lines
end

local function render()
  local buf, win = state.buf, state.win
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end

  local lines = content_lines()

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Highlight the tab bar: active tab stands out, others dimmed.
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, r in ipairs(state.tab_ranges) do
    local group = (r.idx == state.idx) and "CheatTabActive" or "CheatTabInactive"
    vim.api.nvim_buf_add_highlight(buf, ns, group, 0, r.s, r.e)
  end
  vim.api.nvim_buf_add_highlight(buf, ns, "Comment", 1, 0, -1)

  -- Resize / recenter to fit current page.
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width + 2, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 4)

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_config(win, {
      relative = "editor",
      row = math.floor((vim.o.lines - height) / 2),
      col = math.floor((vim.o.columns - width) / 2),
      width = width,
      height = height,
      title = " Cheatsheet — " .. sheets[state.idx].name .. " ",
      title_pos = "center",
    })
  end
end

local function switch(idx)
  if idx < 1 then idx = #sheets end
  if idx > #sheets then idx = 1 end
  state.idx = idx
  render()
end

function M.show()
  collect_recent()
  state.idx = 1

  local buf = vim.api.nvim_create_buf(false, true)
  state.buf = buf
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "help_cheatsheet"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor(vim.o.lines / 4),
    col = math.floor(vim.o.columns / 4),
    width = 60,
    height = 20,
    style = "minimal",
    border = "rounded",
    title = " Cheatsheet ",
    title_pos = "center",
  })
  state.win = win

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local map = function(lhs, rhs)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true })
  end

  map("<Esc>", close)
  map("q", close)

  -- Tab navigation
  map("<Tab>", function() switch(state.idx + 1) end)
  map("<S-Tab>", function() switch(state.idx - 1) end)
  map("l", function() switch(state.idx + 1) end)
  map("h", function() switch(state.idx - 1) end)
  map("]", function() switch(state.idx + 1) end)
  map("[", function() switch(state.idx - 1) end)

  -- Click a tab to switch
  map("<LeftMouse>", function()
    local p = vim.fn.getmousepos()
    if p.winid == win and p.line == 1 then
      for _, r in ipairs(state.tab_ranges) do
        if p.column >= r.s + 1 and p.column <= r.e then
          switch(r.idx)
          return
        end
      end
    end
  end)

  -- Numbers open recent project files (Vim page only)
  for i = 1, 3 do
    map(tostring(i), function()
      if state.idx == 1 and state.recent[i] then
        close()
        vim.cmd("edit " .. vim.fn.fnameescape(state.cwd .. "/" .. state.recent[i]))
      end
    end)
  end

  render()
end

function M.setup()
  vim.api.nvim_set_hl(0, "CheatTabActive", { link = "PmenuSel", default = true })
  vim.api.nvim_set_hl(0, "CheatTabInactive", { link = "Comment", default = true })

  vim.api.nvim_create_user_command("Cheatsheet", M.show, {
    desc = "Show custom keybindings cheatsheet (tabbed: Vim/Console/AWS/Claude)",
  })
end

return M
