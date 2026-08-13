-- Text-to-speech via macOS `say` (Ava Premium) — mirrors ~/.hammerspoon: the
-- whole text is spoken by ONE `say` process (smooth, no per-chunk gaps), with
-- [[slnc]] pauses so sentences/list items don't run together. Markdown is
-- stripped so symbols aren't read aloud. No live word highlighting (`say` has no
-- per-word callback) — stop with \sq or by pressing F8 again.
local M = {}

local vu = require("config.vim_util")

local SAY_VOICE = "Ava (Premium)"
local tts_job = nil

-- Stop the current speech; returns true if something was speaking.
function M.stop()
  if tts_job then
    vim.fn.jobstop(tts_job)
    tts_job = nil
    return true
  end
  return false
end

-- Clean markdown to speakable text, then insert [[slnc N]] pauses (ms) so the
-- reading is paced. Pauses are added LAST so the symbol-stripping passes above
-- don't eat their [[ ]] brackets.
local function prepare(text)
  text = text:gsub("\r\n", "\n")
  -- Fenced code blocks -> placeholder; inline code -> its contents.
  text = text:gsub("```.-```", " code block. ")
  text = text:gsub("`([^`]+)`", "%1")
  -- Images ![alt](url) -> alt ; links [text](url) -> text.
  text = text:gsub("!%[([^%]]*)%]%([^%)]*%)", "%1")
  text = text:gsub("%[([^%]]*)%]%([^%)]*%)", "%1")
  -- HTML tags.
  text = text:gsub("<[^>]->", "")
  -- Line-level markers: headers, blockquotes, list bullets, table/hr rules.
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local bare = line:gsub("%s", "")
    if #bare >= 3 and bare:match("^[-=_*|:]+$") then
      line = "" -- horizontal rule or table separator
    else
      line = line:gsub("^%s*#+%s+", "")     -- header
      line = line:gsub("^%s*>+%s*", "")     -- blockquote
      line = line:gsub("^%s*[-*+]%s+", "")  -- bullet
      line = line:gsub("^%s*%d+[.)]%s+", "") -- numbered item
    end
    out[#out + 1] = line
  end
  text = table.concat(out, "\n")
  -- Emphasis markers and stray symbols that get mispronounced.
  text = text:gsub("%*+", ""):gsub("__+", "")
  text = text:gsub("[~^|\\`{}%[%]]", " ")
  -- Pauses (values mirror ~/.hammerspoon): line breaks, sentence/clause, comma.
  text = text:gsub("%s*\n+%s*", " [[slnc 550]] ")
  text = text:gsub("([%.%?!:;])(%s)", "%1 [[slnc 350]]%2")
  text = text:gsub("(,)(%s)", "%1 [[slnc 200]]%2")
  -- Normalise runs of spaces/tabs (leaves [[slnc N]] intact).
  text = text:gsub("[ \t]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  return text
end

-- Speak `text` with a single `say` process (stops any current speech first).
function M.say(text)
  M.stop()
  text = prepare(text)
  if text == "" then return end
  tts_job = vim.fn.jobstart({ "say", "-v", SAY_VOICE }, {
    on_exit = function() tts_job = nil end,
  })
  if tts_job <= 0 then
    tts_job = nil
    vim.notify("TTS: failed to start `say`", vim.log.levels.ERROR)
    return
  end
  vim.fn.chansend(tts_job, text)
  vim.fn.chanclose(tts_job, "stdin")
end

-- F8 (normal): speak from the cursor line to end of buffer; press again to stop.
function M.toggle_read_from_cursor()
  if M.stop() then return end
  local buf = vim.api.nvim_get_current_buf()
  local from = vim.api.nvim_win_get_cursor(0)[1] - 1
  M.say(table.concat(vim.api.nvim_buf_get_lines(buf, from, -1, false), "\n"))
end

-- Visual selection → speak (line-granular, like the old engine).
local function speak_selection()
  local buf = vim.api.nvim_get_current_buf()
  local s = vim.api.nvim_buf_get_mark(buf, "<")
  local e = vim.api.nvim_buf_get_mark(buf, ">")
  if s[1] == 0 then return end
  M.say(table.concat(vim.api.nvim_buf_get_lines(buf, s[1] - 1, e[1], false), "\n"))
end

-- Visual-mode mapping body: commit the marks, then speak the selection.
function M.speak_selection_mapping()
  vu.leave_visual_mode()
  vim.schedule(speak_selection)
end

return M
