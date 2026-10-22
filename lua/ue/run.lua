-- Rider-style run configurations for Unreal projects.
--
-- Generated from the project the way Rider does it: one configuration per
-- (target in Source/*.Target.cs) x (configuration the engine can build), named like Rider's
-- dropdown ("DebugGame Editor", "DebugGame", "Development Editor", "Development", "Shipping").
-- Every launch builds first, then starts the program under the debugger (nvim-dap) or detached
-- without it. The selected configuration is remembered per project.
--
-- One engine and platform per Neovim, the one native to where it runs (core/context.lua):
--   * Windows: UBT.nvim, Win64 binaries, the DbgEng debugger (tools/dbgeng-dap).
--   * WSL in a Windows project, no engine installed in WSL for it (ctx.wsl_ue): the Windows engine
--     through WSL interop: Windows' UnrealBuildTool.exe, the Win64 binaries, and dbgeng-dap run by
--     Windows' Python, which translates the /mnt/<drive>/ paths (lang-cpp.lua).
--   * Linux / macOS, and WSL with an engine installed in WSL (ctx.ue_unix): Epic's Build.sh, the
--     Linux / Mac binaries, codelldb.
local ctx = require('core.context')

local M = {}

local P = ctx.wsl_ue or ctx.ue_unix
local host = ctx.is_ue and 'windows' or ctx.wsl_ue and 'wsl' or ctx.ue_unix and 'unix' or nil
local PLATFORM = host == 'unix' and P.platform or 'Win64'
local ROOT = ctx.ue_project_root or (P and P.root)
local NAME = ctx.ue_project_name or (P and P.name)

local CONFIG_ORDER = { 'Debug', 'DebugGame', 'Development', 'Test', 'Shipping' }
-- Rider's order within a configuration: suffixed types alphabetically, the plain Game target last
-- ("DebugGame Editor", "DebugGame Server", "DebugGame").
local TYPE_ORDER = { Client = 1, Editor = 2, Program = 3, Server = 4, Game = 5 }
local TYPE_SUFFIX = { Editor = ' Editor', Game = '', Client = ' Client', Server = ' Server', Program = ' Program' }
-- An installed (launcher/binary) engine ships only these; a source engine can build all of CONFIG_ORDER.
local INSTALLED_CONFIGS = {
  Editor = { DebugGame = true, Development = true },
  Other = { DebugGame = true, Development = true, Shipping = true },
}

local cache = {}
local running -- vim.SystemObj of the last program started without the debugger
local build_job -- vim.SystemObj of the build outside Windows (UBT.nvim's own job on Windows)
local build_cancelled = false

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'UE run' })
end

--- Run configurations exist here: an Unreal project, on any of the hosts above.
function M.available()
  return host ~= nil
end

local function uproject()
  return ROOT and (ROOT .. '/' .. NAME .. '.uproject')
end

--- The .uproject as the program reads it: a Windows path for a Windows program started from WSL.
local function uproject_arg()
  return host == 'wsl' and (P.win_root .. '/' .. NAME .. '.uproject') or uproject()
end

--- Engine root as a path here: on Windows UNL's finder (registry / path / GUID builds), elsewhere
--- ue/compiledb_unix.lua's (the compile database's, $UE_ENGINE_ROOT, EngineAssociation, Install.ini).
function M.engine_root()
  if cache.engine == nil then
    local root
    if host == 'windows' then
      local ok, finder = pcall(require, 'UNL.finder')
      if ok then root = finder.engine.find_engine_root(uproject()) end
    elseif host then
      root = require('ue.compiledb_unix').engine_root()
    end
    cache.engine = root and vim.fs.normalize(root) or false
  end
  return cache.engine or nil
end

local function project_targets()
  local out = {}
  for _, f in ipairs(vim.fn.glob(ROOT .. '/Source/*.Target.cs', false, true)) do
    local text = table.concat(vim.fn.readfile(f), '\n')
    local ty = text:match('Type%s*=%s*TargetType%.(%a+)')
    if ty and TYPE_ORDER[ty] then
      out[#out + 1] = { name = (vim.fn.fnamemodify(f, ':t'):gsub('%.Target%.cs$', '')), type = ty }
    end
  end
  return out
end

--- UBT's binary for a target: <dir>/Binaries/<Platform>/<Name>[-<Platform>-<Configuration>][.exe];
--- on macOS inside its .app bundle.
local function binary(dir, name, config)
  local file = name .. (config == 'Development' and '' or ('-' .. PLATFORM .. '-' .. config))
  if PLATFORM == 'Mac' then
    return ('%s/Binaries/Mac/%s.app/Contents/MacOS/%s'):format(dir, file, file)
  end
  return ('%s/Binaries/%s/%s%s'):format(dir, PLATFORM, file, PLATFORM == 'Win64' and '.exe' or '')
end

local function program_for(target, config, engine)
  if target.type == 'Editor' then
    return binary(engine .. '/Engine', 'UnrealEditor', config), { uproject_arg() }
  end
  return binary(ROOT, target.name, config), {}
end

--- All run configurations, in Rider's order.
function M.list()
  if cache.list then return cache.list end
  local engine = M.engine_root()
  if not host or not engine then return {} end
  local installed = vim.uv.fs_stat(engine .. '/Engine/Build/InstalledBuild.txt') ~= nil
  local targets = project_targets()
  local per_type = {}
  for _, t in ipairs(targets) do per_type[t.type] = (per_type[t.type] or 0) + 1 end

  local list = {}
  for ci, config in ipairs(CONFIG_ORDER) do
    for _, t in ipairs(targets) do
      local allowed = not installed or INSTALLED_CONFIGS[t.type == 'Editor' and 'Editor' or 'Other'][config]
      if allowed then
        local program, args = program_for(t, config, engine)
        local name = config .. TYPE_SUFFIX[t.type] .. (per_type[t.type] > 1 and (' (' .. t.name .. ')') or '')
        list[#list + 1] = {
          name = name, target = t.name, type = t.type, configuration = config, platform = PLATFORM,
          program = program, args = args, cwd = engine, engine = engine,
          _order = ci * 10 + TYPE_ORDER[t.type],
        }
      end
    end
  end
  table.sort(list, function(a, b) return a._order < b._order end)
  cache.list = list
  return list
end

--- UBT.nvim presets for the same configurations (build uses the configuration's name as preset label).
function M.ubt_presets()
  local presets = {}
  for _, c in ipairs(M.list()) do
    presets[#presets + 1] = {
      name = c.name, TargetName = c.target, Platform = c.platform,
      IsEditor = c.type == 'Editor', Configuration = c.configuration,
    }
  end
  return presets
end

function M.find(name)
  for _, c in ipairs(M.list()) do
    if c.name == name then return c end
  end
end

-- Selected configuration, remembered per project (like Rider's run configuration dropdown).
-- WSL keeps its own file: its configurations are the same names, but a WSL engine's are Linux ones.
local function state_file()
  return vim.fn.stdpath('state') .. '/ue-run/' .. (NAME or 'none') .. '.json'
end

function M.selected()
  if cache.selected == nil then
    local ok, data = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(state_file()), '\n')) end)
    cache.selected = ok and type(data) == 'table' and data.selected or false
  end
  return (cache.selected and M.find(cache.selected)) or M.list()[1]
end

function M.select_name(name)
  cache.selected = name
  vim.fn.mkdir(vim.fn.fnamemodify(state_file(), ':h'), 'p')
  vim.fn.writefile({ vim.json.encode({ selected = name }) }, state_file())
  vim.cmd.redrawstatus()
end

--- Pick a configuration; with `then_fn`, run it on the picked configuration afterwards.
function M.pick(then_fn)
  local list = M.list()
  if #list == 0 then return notify('No run configurations (engine or *.Target.cs not found)', vim.log.levels.WARN) end
  local current = M.selected()
  vim.ui.select(list, {
    prompt = 'Run configuration',
    format_item = function(c) return (c == current and '● ' or '  ') .. c.name end,
  }, function(choice)
    if not choice then return end
    M.select_name(choice.name)
    if then_fn then then_fn(choice) end
  end)
end

-- Builds outside Windows ----------------------------------------------------------------------------

local build_log = vim.fn.stdpath('cache') .. '/ue-build.log'

--- UBT command and working directory for a configuration.
local function build_command(cfg)
  if host == 'wsl' then
    -- as Build.bat runs it (ue/compiledb_unix.lua does the same for the compile database)
    return { cfg.engine .. '/Engine/Binaries/DotNET/UnrealBuildTool/UnrealBuildTool.exe', cfg.target, 'Win64',
      cfg.configuration, '-project=' .. uproject_arg(), '-WaitMutex' }, cfg.engine .. '/Engine/Source'
  end
  return { cfg.engine .. '/Engine/Build/BatchFiles/' .. PLATFORM .. '/Build.sh', cfg.target, PLATFORM,
    cfg.configuration, '-project=' .. uproject_arg(), '-WaitMutex' }, cfg.engine
end

--- A compiler's file path as a path here (UBT on Windows prints D:\x from WSL).
local function here(path)
  path = path:gsub('\\', '/')
  local drive, rest = path:match('^(%a):(/.*)$')
  if host == 'wsl' and drive then
    path = '/mnt/' .. drive:lower() .. rest
    -- the project's files under the root as spelled here (DrvFs ignores case; buffers do not)
    if path:sub(1, #P.root + 1):lower() == P.root:lower() .. '/' then
      path = P.root .. path:sub(#P.root + 1)
    end
  end
  return path
end

--- Errors from the build output for the quickfix list (MSVC "file(line[,col]): error C1234: text",
--- clang "file:line:col: error: text"; UBT prints both forms for its own errors).
local function quickfix_items(output)
  local items, seen = {}, {}
  for line in output:gmatch('[^\r\n]+') do
    local file, lnum, col, text = line:match('^%s*(.-)%((%d+),?(%d*)%)%s*:%s*fatal error%s*(.*)$')
    if not file then file, lnum, col, text = line:match('^%s*(.-)%((%d+),?(%d*)%)%s*:%s*error%s*(.*)$') end
    if not file then file, lnum, col, text = line:match('^%s*(.-):(%d+):(%d+):%s*fatal error:%s*(.*)$') end
    if not file then file, lnum, col, text = line:match('^%s*(.-):(%d+):(%d+):%s*error:%s*(.*)$') end
    if file and file ~= '' and not seen[line] then
      seen[line] = true
      items[#items + 1] = { filename = here(file), lnum = tonumber(lnum), col = tonumber(col) or 1, text = text, type = 'E' }
    end
  end
  return items
end

local function build_unix(cfg, on_success)
  if build_job then return notify('A build is already running (Shift+F5 stops it)', vim.log.levels.WARN) end
  local cmd, cwd = build_command(cfg)
  if vim.fn.executable(cmd[1]) ~= 1 then return notify('Not found: ' .. cmd[1], vim.log.levels.ERROR) end
  notify('Building ' .. cfg.name .. ' ...')
  local t0 = vim.uv.hrtime()
  local ok, job = pcall(vim.system, cmd, { cwd = cwd, text = true }, vim.schedule_wrap(function(res)
    build_job = nil
    local output = (res.stdout or '') .. (res.stderr or '')
    local f = io.open(build_log, 'w')
    if f then
      f:write(('$ %s\n(cwd %s, exit %d)\n\n%s'):format(table.concat(cmd, ' '), cwd, res.code, output))
      f:close()
    end
    local secs = (vim.uv.hrtime() - t0) / 1e9
    if build_cancelled then
      build_cancelled = false
      return notify('Build cancelled: ' .. cfg.name)
    end
    if res.code == 0 then
      notify(('Build succeeded: %s (%ds)'):format(cfg.name, secs))
      if on_success then on_success(cfg) end
      return
    end
    local items = quickfix_items(output)
    vim.fn.setqflist({}, ' ', { title = 'Build ' .. cfg.name, items = items })
    notify(('Build FAILED: %s (%ds), %s'):format(cfg.name, secs,
      #items > 0 and (#items .. ' errors in the quickfix list') or ('output in ' .. build_log)), vim.log.levels.ERROR)
    if #items > 0 then vim.cmd('botright copen') end
  end))
  if not ok then return notify('Failed to start the build: ' .. tostring(job), vim.log.levels.ERROR) end
  build_job = job
end

--- Build; `on_success` runs only after a successful build. On Windows UBT.nvim builds (its own echo is
--- off, lang-ue.lua, so the result is reported here; a failed build opens its diagnostics picker).
function M.build(cfg, on_success)
  cfg = cfg or M.selected()
  if not cfg then return notify('No run configuration selected', vim.log.levels.WARN) end
  if host ~= 'windows' then return build_unix(cfg, on_success) end
  require('lazy').load({ plugins = { 'UBT.nvim' } })
  -- UBT.nvim runs one job at a time: starting the build would stop a compile DB update (a few
  -- seconds), and the stopped job's exit handler would then clear the build's job id.
  local cdb = require('ue.compiledb')
  if cdb.running() then
    notify('Waiting for the compile_commands.json update ...')
    local timer = assert(vim.uv.new_timer())
    timer:start(500, 500, vim.schedule_wrap(function()
      if cdb.running() then return end
      timer:stop()
      timer:close()
      M.build(cfg, on_success)
    end))
    return
  end
  notify('Building ' .. cfg.name .. ' ...')
  require('UBT.api').build({
    label = cfg.name,
    on_complete = function(result)
      local secs = result and result.elapsed_s or 0
      if build_cancelled then
        build_cancelled = false
        notify('Build cancelled: ' .. cfg.name)
      elseif result and result.success then
        notify(('Build succeeded: %s (%ds)'):format(cfg.name, secs))
        pcall(cdb.after_build)
        if on_success then on_success(cfg) end
      else
        notify(('Build FAILED: %s (%ds) - <leader>be lists the errors'):format(cfg.name, secs), vim.log.levels.ERROR)
        pcall(function() require('UBT.api').diagnostics() end)
      end
    end,
  })
end

local function ue_starting()
  if host == 'windows' then
    pcall(function() require('ue.clangd_index').ue_starting() end) -- fewer clangd threads while it runs
  end
end

--- The debugger: DbgEng for Win64 programs (also from WSL), codelldb for Linux / Mac ones.
local function dap_launch(cfg)
  local dap = require('dap')
  local adapter = PLATFORM == 'Win64' and dap.adapters.dbgeng and 'dbgeng' or 'codelldb'
  if not dap.adapters[adapter] then
    return notify('No debug adapter (' .. adapter .. ') is set up', vim.log.levels.ERROR)
  end
  ue_starting()
  dap.run({
    name = 'UE: ' .. cfg.name, type = adapter, request = 'launch',
    program = cfg.program, args = cfg.args, cwd = cfg.cwd,
    engineRoot = cfg.engine, -- dbgeng: Unreal.natvis also for game executables outside Engine/Binaries
  })
end

local function start_detached(cfg, extra_args)
  if not vim.uv.fs_stat(cfg.program) then
    return notify('Not built yet: ' .. cfg.program, vim.log.levels.ERROR)
  end
  local cmd = { cfg.program }
  vim.list_extend(cmd, cfg.args)
  vim.list_extend(cmd, extra_args or {})
  ue_starting()
  local ok, obj = pcall(vim.system, cmd, { cwd = cfg.cwd, detach = true, stdout = false, stderr = false })
  if not ok then return notify('Failed to start: ' .. tostring(obj), vim.log.levels.ERROR) end
  running = obj
  notify(('Started %s (pid %d)'):format(cfg.name, obj.pid))
end

--- F5: build, then launch under the debugger.
function M.debug(cfg)
  M.build(cfg, dap_launch)
end

--- Ctrl+F5: build, then run without the debugger.
function M.run(cfg)
  M.build(cfg, function(c) start_detached(c) end)
end

--- Run without building (the editor gets -skipcompile, like RunDevWithoutCompile.bat).
function M.run_no_build(cfg)
  cfg = cfg or M.selected()
  if not cfg then return end
  start_detached(cfg, cfg.type == 'Editor' and { '-skipcompile' } or nil)
end

--- Shift+F5: stop the debug session, else the program started with run, else the build.
--- (From WSL, ending the WSL side of a Windows program ends the program.)
function M.stop()
  local ok, dap = pcall(require, 'dap')
  if ok and dap.session() then return dap.terminate() end
  if running and not running:is_closing() then
    running:kill(15)
    return notify('Stopped (pid ' .. running.pid .. ')')
  end
  if build_job then
    build_cancelled = true
    build_job:kill(15)
  elseif package.loaded['UBT.api'] then
    build_cancelled = true
    pcall(require('UBT.api').cancel_build)
  end
end

--- Statusline text: the selected configuration.
function M.status()
  local c = host and M.selected()
  return c and c.name or ''
end

--- Keys outside Windows, where the UBT.nvim spec that maps them on Windows (lang-ue.lua) is not loaded.
function M.setup_keys()
  if host == 'windows' or not host then return end
  -- stylua: ignore
  local keys = {
    { '<C-F5>', M.run, 'Run selected configuration (no debugger)' },
    { '<C-S-b>', M.build, 'Build selected configuration' },
    { '<leader>bc', M.pick, 'Choose run configuration' },
    { '<leader>bb', M.build, 'Build selected configuration' },
    { '<leader>bB', function() M.pick(M.build) end, 'Build (pick configuration)' },
    { '<leader>bD', M.debug, 'Debug selected configuration' },
    { '<leader>bS', function() M.pick(M.debug) end, 'Debug (pick configuration)' },
    { '<leader>bx', M.run, 'Run selected configuration' },
    { '<leader>bX', function() M.pick(M.run) end, 'Run (pick configuration)' },
    { '<leader>bR', M.run_no_build, 'Run selected without building' },
    { '<leader>bs', M.stop, 'Stop (debug session / run / build)' },
    { '<leader>be', function() vim.cmd('botright copen') end, 'Build errors (quickfix list)' },
  }
  for _, k in ipairs(keys) do
    vim.keymap.set('n', k[1], function() k[2]() end, { desc = k[3] })
  end
end

return M
