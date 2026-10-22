-- Live Coding from Neovim (Rider's "Build and Reload", the editor's Ctrl+Alt+F11).
--
-- While an editor runs Live Coding, UBT refuses to build its target ("Unable to build while Live Coding
-- is active", HotReload.cs), so a build from here failed. Editors started by ue/run.lua get -cmdlink:
-- Epic's CmdLinkServer plugin (enabled by default, Win64 editors) then runs console commands sent over
-- a named pipe (tools/ue-cmdlink/cmdlink.ps1), and a build sends `LiveCoding.Compile` instead. That
-- command starts Live Coding for the session if it is off (LiveCodingModule.cpp Compile ->
-- EnableForSession). The pipe is keyed by project name, so two projects' editors do not share one.
-- From WSL the client runs through interop like the other Windows tools.
local ctx = require('core.context')

local M = {}

local P = ctx.wsl_ue
local NAME = ctx.ue_project_name or (P and P.name)

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'Live Coding' })
end

--- Pipe name for this project's editor (console.CmdLink.key).
function M.key()
  return NAME and (NAME:gsub('[^%w_-]', '_')) or nil
end

--- Editor arguments that open the pipe (-ini: sets the console variable before the plugin starts).
function M.launch_args()
  local key = M.key()
  if not key or not (ctx.is_ue or P) then return {} end
  return { '-cmdlink', '-ini:Engine:[ConsoleVariables]:console.CmdLink.key=' .. key }
end

local script
local function client()
  if script == nil then
    local path = vim.fn.stdpath('config') .. '/tools/ue-cmdlink/cmdlink.ps1'
    if P then
      local res = vim.system({ 'wslpath', '-w', path }, { text = true }):wait(3000)
      path = res.code == 0 and vim.trim(res.stdout or '') or nil
    end
    script = path or false
  end
  return script or nil
end

--- Calls back (main loop) with true when an UnrealEditor process runs on Windows.
local function editor_running(cb)
  local exe = P and 'tasklist.exe' or 'tasklist'
  local ok = pcall(vim.system, { exe, '/FI', 'IMAGENAME eq UnrealEditor*', '/FO', 'CSV', '/NH' }, { text = true },
    vim.schedule_wrap(function(res)
      cb(res.code == 0 and (res.stdout or ''):lower():find('"unrealeditor', 1, true) ~= nil)
    end))
  if not ok then cb(false) end
end

--- Runs a console command in this project's editor; cb(code, reply): 0 replied, 2 no editor on the pipe.
function M.exec(command, cb)
  local ps1 = client()
  if not ps1 then return cb(-1, 'cmdlink.ps1 not found') end
  local cmd = { P and 'powershell.exe' or 'powershell', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', ps1, '-Pipe', 'UnrealEngine-CLI-' .. M.key(), '-Command', command }
  local ok = pcall(vim.system, cmd, { text = true }, vim.schedule_wrap(function(res)
    cb(res.code, vim.trim((res.stdout or '') .. (res.stderr or '')))
  end))
  if not ok then cb(-1, 'powershell not found') end
end

-- The result comes back in the editor's log (Saved/Logs/<Project>.log), e.g. "LogLiveCoding: Display: Live
-- coding succeeded, no code changes detected": its new lines are read every second for up to 10 minutes.
local watching
local function log_path()
  return (ctx.ue_project_root or (P and P.root)) .. '/Saved/Logs/' .. NAME .. '.log'
end

-- The compile itself is UBT's (-LiveCoding), which writes its log to %LOCALAPPDATA%/UnrealBuildTool/Log.txt
-- (rewritten by the Live Coding compile tested on V2). Its compiler errors go to the quickfix list like a
-- failed build's (ue/run.lua). Assumption: the errors appear there in MSVC form, as in a normal build's
-- output; no failing Live Coding compile was run (it needs a broken project file).
local function ubt_log()
  local dir = vim.env.LOCALAPPDATA
  if P then
    local res = vim.system({ 'cmd.exe', '/c', 'echo %LOCALAPPDATA%' }, { text = true }):wait(3000)
    local win = res.code == 0 and vim.trim(res.stdout or '') or ''
    res = win ~= '' and vim.system({ 'wslpath', '-u', win }, { text = true }):wait(3000) or nil
    dir = res and res.code == 0 and vim.trim(res.stdout or '') or nil
  end
  return dir and (dir .. '/UnrealBuildTool/Log.txt') or nil
end

local function show_errors(result)
  local path = ubt_log()
  local f = path and io.open(path, 'rb')
  local items = {}
  if f then
    items = require('ue.run').quickfix_items(f:read('*a') or '')
    f:close()
  end
  vim.fn.setqflist({}, ' ', { title = 'Live Coding', items = items })
  notify(result .. (#items > 0 and ('\n' .. #items .. ' errors in the quickfix list')
    or '\nThe Live Coding window in the editor has the output'), vim.log.levels.ERROR)
  if #items > 0 then vim.cmd('botright copen') end
end

--- `offset`: the log's size before the compile was asked for.
local function report_result(offset)
  local path = log_path()
  local rest, ticks = '', 0
  if watching and not watching:is_closing() then watching:stop(); watching:close() end
  local timer = assert(vim.uv.new_timer())
  watching = timer
  local function done()
    if not timer:is_closing() then timer:stop(); timer:close() end
  end
  timer:start(1000, 1000, vim.schedule_wrap(function()
    ticks = ticks + 1
    if ticks > 600 then return done() end
    local now = vim.uv.fs_stat(path)
    if not now then return end
    if now.size < offset then offset = 0 end -- a new log (editor restarted)
    if now.size == offset then return end
    local f = io.open(path, 'rb')
    if not f then return end
    f:seek('set', offset)
    local text = rest .. (f:read(now.size - offset) or '')
    f:close()
    offset = now.size
    rest = text:match('[^\n]*$') or ''
    for line in text:sub(1, #text - #rest):gmatch('[^\r\n]+') do
      -- LiveCodingModule.cpp (5.6 / 5.8): "Live coding succeeded[, ...]" (Display, or Warning for data type
      -- changes), "Live coding canceled", "Live coding failed, please see Live console ..." (Error)
      local verbosity, result = line:match('LogLiveCoding: (%w+): (Live coding %a+.*)$')
      if result then
        done()
        if result:find('failed', 1, true) then return show_errors(result) end
        local level = verbosity == 'Display' and vim.log.levels.INFO or vim.log.levels.WARN
        return notify(result, level)
      end
    end
  end))
end

--- Starts a Live Coding compile in this project's running editor. cb(true) when the editor took it;
--- cb(false) when no editor of ours runs (the caller builds with UBT instead).
function M.compile(cb)
  cb = cb or function() end
  if not M.key() then return cb(false) end
  editor_running(function(running)
    if not running then return cb(false) end
    local st = vim.uv.fs_stat(log_path())
    local offset = st and st.size or 0
    M.exec('LiveCoding.Compile', function(code, reply)
      if code == 0 then
        notify('Compiling in the editor (Live Coding) ...')
        report_result(offset)
        return cb(true)
      end
      if code == 2 then
        notify('UnrealEditor runs without -cmdlink (not started from Neovim): building with UBT. With Live Coding on, '
          .. 'UBT refuses; press Ctrl+Alt+F11 in the editor instead', vim.log.levels.WARN)
      else
        notify('Live Coding request failed (' .. code .. '): ' .. reply, vim.log.levels.WARN)
      end
      cb(false)
    end)
  end)
end

return M
