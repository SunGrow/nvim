-- Rider-style run configurations for Unreal projects.
--
-- Generated from the project the way Rider does it: one configuration per
-- (target in Source/*.Target.cs) x (configuration the engine can build), named like Rider's
-- dropdown ("DebugGame Editor", "DebugGame", "Development Editor", "Development", "Shipping").
-- Every launch builds first (UBT.nvim), then starts the program under the debugger (nvim-dap,
-- DbgEng adapter) or detached without it. The selected configuration is remembered per project.
local ctx = require('core.context')

local M = {}

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
local build_cancelled = false

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'UE run' })
end

local function uproject()
  return ctx.ue_project_root and (ctx.ue_project_root .. '/' .. ctx.ue_project_name .. '.uproject')
end

--- Engine root for the project's EngineAssociation (UNL's finder: registry / path / GUID builds).
function M.engine_root()
  if cache.engine == nil then
    local root
    local ok, finder = pcall(require, 'UNL.finder')
    if ok and uproject() then
      root = finder.engine.find_engine_root(uproject())
    end
    cache.engine = root and vim.fs.normalize(root) or false
  end
  return cache.engine or nil
end

local function project_targets()
  local out = {}
  for _, f in ipairs(vim.fn.glob(ctx.ue_project_root .. '/Source/*.Target.cs', false, true)) do
    local text = table.concat(vim.fn.readfile(f), '\n')
    local ty = text:match('Type%s*=%s*TargetType%.(%a+)')
    if ty and TYPE_ORDER[ty] then
      out[#out + 1] = { name = (vim.fn.fnamemodify(f, ':t'):gsub('%.Target%.cs$', '')), type = ty }
    end
  end
  return out
end

local function program_for(target, config, engine)
  local suffix = config == 'Development' and '' or ('-Win64-' .. config)
  if target.type == 'Editor' then
    return engine .. '/Engine/Binaries/Win64/UnrealEditor' .. suffix .. '.exe', { uproject() }
  end
  return ctx.ue_project_root .. '/Binaries/Win64/' .. target.name .. suffix .. '.exe', {}
end

--- All run configurations, in Rider's order.
function M.list()
  if cache.list then return cache.list end
  local engine = M.engine_root()
  if not ctx.is_ue or not engine then return {} end
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
          name = name, target = t.name, type = t.type, configuration = config, platform = 'Win64',
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
local function state_file()
  return vim.fn.stdpath('state') .. '/ue-run/' .. (ctx.ue_project_name or 'none') .. '.json'
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

--- Build with UBT.nvim; `on_success` runs only after a successful build. UBT's own echo is off
--- (lang-ue.lua), so the result is reported here; a failed build opens the diagnostics picker.
function M.build(cfg, on_success)
  cfg = cfg or M.selected()
  if not cfg then return notify('No run configuration selected', vim.log.levels.WARN) end
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

local function dap_launch(cfg)
  local dap = require('dap')
  local adapter = dap.adapters.dbgeng and 'dbgeng' or 'codelldb'
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

--- Shift+F5: stop the debug session, else the program started with run.
function M.stop()
  local ok, dap = pcall(require, 'dap')
  if ok and dap.session() then return dap.terminate() end
  if running and not running:is_closing() then
    running:kill(15)
    return notify('Stopped (pid ' .. running.pid .. ')')
  end
  if package.loaded['UBT.api'] then
    build_cancelled = true
    pcall(require('UBT.api').cancel_build)
  end
end

--- Statusline text: the selected configuration.
function M.status()
  local c = ctx.is_ue and M.selected()
  return c and c.name or ''
end

return M
