-- zenserver before an Unreal Editor starts (tools/ue-zen/zen.ps1 has the why and how).
--
-- An editor launched by ue/run.lua waits here until the shared zenserver answers health/ready (a start
-- took 1-44 s on this machine; the editor's own launch gives up after 20 s with a modal dialog), then
-- starts with -NoZenAutoLaunch and becomes the server's sponsor: the server ends with the last editor.
-- Win64 editors only (also from WSL, through interop); vim.g.ue_zen = false turns it off.
local ctx = require('core.context')

local M = {}

local P = ctx.wsl_ue

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'Zen' })
end

local script
local function client()
  if script == nil then
    local path = vim.fn.stdpath('config') .. '/tools/ue-zen/zen.ps1'
    if P then
      local res = vim.system({ 'wslpath', '-w', path }, { text = true }):wait(3000)
      path = res.code == 0 and vim.trim(res.stdout or '') or nil
    end
    script = path or false
  end
  return script or nil
end

local function ps(args, on_line, on_exit)
  local cmd = { P and 'powershell.exe' or 'powershell', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', client() }
  vim.list_extend(cmd, args)
  local rest = ''
  local ok, err = pcall(vim.system, cmd, {
    text = true,
    stdout = function(_, chunk)
      if not chunk then return end
      rest = rest .. chunk
      for line in rest:gmatch('([^\r\n]+)\r?\n') do vim.schedule(function() on_line(line) end) end
      rest = rest:match('[^\n]*$') or ''
    end,
  }, vim.schedule_wrap(function(res) on_exit(res.code) end))
  if not ok then vim.schedule(function() on_exit(-1, err) end) end
end

--- Whether an editor launch goes through here.
function M.enabled(cfg)
  return vim.g.ue_zen ~= false and cfg.type == 'Editor' and cfg.platform == 'Win64' and client() ~= nil
end

--- Makes sure zenserver is ready, then `launch(extra_args)`: { '-NoZenAutoLaunch' } once it is, {} when
--- it could not be (the editor launches it as before). After the launch the editor becomes a sponsor.
function M.prepare(launch)
  local keeper, slow, t0 = nil, false, vim.uv.hrtime()
  ps({ '-Mode', 'Start' }, function(line)
    local secs = tonumber(line:match('^WAIT (%d+)'))
    if secs and secs >= 2 and not slow then
      slow = true
      notify('zenserver is starting (it has taken up to a minute here); the editor starts once it answers')
    end
    keeper = tonumber(line:match('^READY (%d+)')) or keeper
  end, function(code)
    if code ~= 0 then
      local why = ({ [4] = 'no zenserver install', [5] = 'not ready after 180 s', [6] = 'it exited while starting' })[code]
        or ('zen.ps1 exit ' .. tostring(code))
      if code ~= 4 then notify('zenserver: ' .. why .. '; the editor launches it itself', vim.log.levels.WARN) end
      return launch({})
    end
    if slow then notify(('zenserver ready (%.0f s)'):format((vim.uv.hrtime() - t0) / 1e9)) end
    launch({ '-NoZenAutoLaunch' })
    -- the editor's process appears right away; it becomes a sponsor, then the placeholder owner goes
    ps({ '-Mode', 'Attach', '-Keeper', tostring(keeper or 0), '-TimeoutS', '30' }, function() end, function(acode)
      if acode ~= 0 then
        notify('zenserver: no editor to keep it running (the editor did not start?); it stops', vim.log.levels.WARN)
      end
    end)
  end)
end

return M
