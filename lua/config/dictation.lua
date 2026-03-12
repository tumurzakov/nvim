-- Vosk streaming dictation plugin for Neovim
-- :DictateToggle (Ctrl+S) — start/stop dictation
-- :DictateLang ru|en — switch language

local M = {}

local job_id = nil
local is_listening = false
local current_lang = "ru"
local script_path = vim.fn.stdpath("config") .. "/lua/tools/vosk_dictation.py"
local is_mac = vim.fn.has("mac") == 1
local is_win = vim.fn.has("win32") == 1

local models_dir
if is_win then
  models_dir = vim.fn.expand("~/AppData/Local/vosk")
else
  models_dir = vim.fn.expand("~/.local/share/vosk")
end

local models = {
  ru = { dir = models_dir .. "/vosk-model-small-ru-0.22", url = "https://alphacephei.com/vosk/models/vosk-model-small-ru-0.22.zip" },
  en = { dir = models_dir .. "/vosk-model-small-en-us-0.15", url = "https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip" },
}

local ns = vim.api.nvim_create_namespace("vosk_dictation")
local downloading = {}

local function ensure_model(lang, callback)
  local m = models[lang]
  if vim.fn.isdirectory(m.dir) == 1 then
    callback(m.dir)
    return
  end
  if downloading[lang] then
    vim.notify("Already downloading " .. lang .. " model...", vim.log.levels.WARN)
    return
  end
  downloading[lang] = true
  vim.fn.mkdir(models_dir, "p")
  local zip_path = models_dir .. "/" .. vim.fn.fnamemodify(m.dir, ":t") .. ".zip"
  vim.notify("Downloading Vosk model [" .. lang .. "]...", vim.log.levels.INFO)
  vim.system(
    { "curl", "-L", "-o", zip_path, m.url },
    { text = true },
    function(result)
      if result.code ~= 0 then
        downloading[lang] = nil
        vim.schedule(function()
          vim.notify("Failed to download Vosk model [" .. lang .. "]", vim.log.levels.ERROR)
        end)
        return
      end
      -- unzip
      local unzip_cmd
      if is_win then
        unzip_cmd = { "powershell", "-NoProfile", "-Command", "Expand-Archive", "-Path", zip_path, "-DestinationPath", models_dir, "-Force" }
      else
        unzip_cmd = { "unzip", "-o", "-d", models_dir, zip_path }
      end
      vim.system(unzip_cmd, { text = true }, function(uz)
        vim.fn.delete(zip_path)
        downloading[lang] = nil
        if uz.code ~= 0 then
          vim.schedule(function()
            vim.notify("Failed to unzip Vosk model [" .. lang .. "]", vim.log.levels.ERROR)
          end)
          return
        end
        vim.schedule(function()
          vim.notify("Vosk model [" .. lang .. "] ready!", vim.log.levels.INFO)
          callback(m.dir)
        end)
      end)
    end
  )
end

local function detect_system_lang()
  if is_mac then
    local result = vim.fn.system("defaults read com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID 2>/dev/null")
    if result:match("Russian") then return "ru" end
  elseif is_win then
    -- PowerShell: get current keyboard layout
    local result = vim.fn.system('powershell -NoProfile -Command "[System.Windows.Forms.InputLanguage]::CurrentInputLanguage.Culture.TwoLetterISOLanguageName"')
    result = vim.trim(result)
    if result == "ru" then return "ru" end
  else
    -- Linux: xdotool, xkblayout-state, or gsettings
    local result = vim.fn.system("xkblayout-state print %s 2>/dev/null || xdotool key --clearmodifiers --get-active-layout 2>/dev/null || gsettings get org.gnome.desktop.input-sources current 2>/dev/null")
    if result:match("ru") or result:match("Russian") then return "ru" end
  end
  return "en"
end

local function show_partial(text)
  vim.schedule(function()
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    if text == "" then return end
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      virt_text = { { " [" .. current_lang .. "] " .. text, "Comment" } },
      virt_text_pos = "eol",
    })
  end)
end

local function clear_partial()
  vim.schedule(function()
    vim.api.nvim_buf_clear_namespace(vim.api.nvim_get_current_buf(), ns, 0, -1)
  end)
end

local function insert_text(text)
  vim.schedule(function()
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local line = vim.api.nvim_get_current_line()
    local before = line:sub(1, col)
    local after = line:sub(col + 1)
    local sep = (before ~= "" and not before:match("%s$")) and " " or ""
    vim.api.nvim_set_current_line(before .. sep .. text .. after)
    vim.api.nvim_win_set_cursor(0, { row, col + #sep + #text })
  end)
end

local function on_stdout(_, data, _)
  for _, raw in ipairs(data) do
    raw = vim.trim(raw)
    if raw == "" then goto continue end

    local ok, msg = pcall(vim.json.decode, raw)
    if not ok then goto continue end

    if msg.type == "status" then
      vim.schedule(function()
        if msg.text == "listening" then
          vim.notify("🎤 [" .. current_lang .. "] Listening...", vim.log.levels.INFO)
        elseif msg.text == "stopped" then
          vim.notify("Dictation stopped", vim.log.levels.INFO)
        elseif msg.text == "ready" then
          vim.notify("Vosk ready [" .. current_lang .. "]", vim.log.levels.INFO)
        elseif msg.text:match("^model_loaded:") then
          vim.notify("Model: " .. msg.text:sub(14), vim.log.levels.INFO)
        end
      end)
    elseif msg.type == "partial" then
      show_partial(msg.text)
    elseif msg.type == "final" then
      clear_partial()
      insert_text(msg.text)
    end

    ::continue::
  end
end

local function on_exit(_, code, _)
  job_id = nil
  is_listening = false
  if code ~= 0 then
    vim.schedule(function()
      vim.notify("Vosk exited with code " .. code, vim.log.levels.ERROR)
    end)
  end
end

local function ensure_running()
  if job_id then return true end
  job_id = vim.fn.jobstart({ "python3", script_path, models[current_lang].dir }, {
    on_stdout = on_stdout,
    on_exit = on_exit,
    stdin = "pipe",
  })
  if job_id <= 0 then
    vim.notify("Failed to start vosk_dictation.py", vim.log.levels.ERROR)
    job_id = nil
    return false
  end
  return true
end

local lang_poll_timer = nil

local function start_lang_poll()
  if lang_poll_timer then return end
  lang_poll_timer = vim.uv.new_timer()
  lang_poll_timer:start(0, 1000, vim.schedule_wrap(function()
    if not is_listening or not job_id then return end
    local sys_lang = detect_system_lang()
    if sys_lang ~= current_lang and models[sys_lang] then
      ensure_model(sys_lang, function(dir)
        current_lang = sys_lang
        if job_id then
          vim.fn.chansend(job_id, "lang " .. dir .. "\n")
        end
      end)
    end
  end))
end

local function stop_lang_poll()
  if lang_poll_timer then
    lang_poll_timer:stop()
    lang_poll_timer:close()
    lang_poll_timer = nil
  end
end

function M.start()
  local sys_lang = detect_system_lang()
  current_lang = sys_lang
  ensure_model(current_lang, function(_)
    if not ensure_running() then return end
    if is_listening then return end
    vim.fn.chansend(job_id, "start\n")
    is_listening = true
    start_lang_poll()
  end)
end

function M.stop()
  if not job_id or not is_listening then return end
  vim.fn.chansend(job_id, "stop\n")
  is_listening = false
  stop_lang_poll()
  clear_partial()
end

function M.toggle()
  if is_listening then
    M.stop()
  else
    M.start()
  end
end

function M.set_lang(lang)
  lang = lang:lower()
  if not models[lang] then
    vim.notify("Unknown lang: " .. lang .. ". Available: ru, en", vim.log.levels.ERROR)
    return
  end
  if lang == current_lang then
    vim.notify("Already [" .. lang .. "]", vim.log.levels.INFO)
    return
  end
  current_lang = lang
  if job_id then
    vim.fn.chansend(job_id, "lang " .. models[lang].dir .. "\n")
  end
end

function M.quit()
  stop_lang_poll()
  if job_id then
    pcall(vim.fn.chansend, job_id, "quit\n")
    pcall(vim.fn.jobstop, job_id)
    job_id = nil
    is_listening = false
  end
  clear_partial()
end

function M.get_listening()
  return is_listening
end

function M.get_lang()
  return current_lang
end

-- Commands
vim.api.nvim_create_user_command("DictateStart", M.start, { desc = "Start voice dictation" })
vim.api.nvim_create_user_command("DictateStop", M.stop, { desc = "Stop voice dictation" })
vim.api.nvim_create_user_command("DictateToggle", M.toggle, { desc = "Toggle voice dictation" })
vim.api.nvim_create_user_command("DictateQuit", M.quit, { desc = "Quit dictation server" })
vim.api.nvim_create_user_command("DictateLang", function(opts)
  M.set_lang(opts.args)
end, {
  nargs = 1,
  complete = function() return { "ru", "en" } end,
  desc = "Switch dictation language",
})

-- F10 to toggle dictation
vim.keymap.set({ "i", "n" }, "<F10>", M.toggle, { desc = "Toggle voice dictation" })

-- Cleanup on exit
vim.api.nvim_create_autocmd("VimLeavePre", { callback = M.quit })

return M
