-- clangd's compile database for Unreal projects outside Windows Neovim. UBT GenerateClangDatabase, with
-- the triggers and the PCH fix of ue/compiledb.lua (Windows), then the clangd clients restart:
--   * WSL in a Windows project (ctx.wsl_ue): Windows' UnrealBuildTool.exe through WSL interop, with
--     Windows paths, run from <Engine>/Engine/Source as Build.bat does. The database stays Windows-shaped
--     for Windows' clangd.exe (lsp.lua).
--   * Linux / macOS (ctx.ue_unix): Epic's Engine/Build/BatchFiles/<Linux|Mac>/Build.sh, which sets up the
--     engine's bundled dotnet and working directory.
-- Generation runs when the database is missing, or older than *.uproject / *.uplugin / *.Build.cs /
-- *.Target.cs (checked at startup), when one of those is saved, and when a project .cpp newer than the
-- database and missing from it is opened or saved. Space bj runs it by hand.
-- Target <Project>Editor <Platform> Development, -NoExecCodeGenActions (UHT headers come from builds),
-- written to the project root.
-- The engine: the database's "directory" (<Engine>/Engine/Source), else $UE_ENGINE_ROOT, else the
-- .uproject EngineAssociation (a path; else the launcher list on Windows, read from WSL; else Install.ini:
-- ~/.config/Epic/UnrealEngine on Linux, ~/Library/Application Support/Epic/UnrealEngine on macOS; else
-- /Users/Shared/Epic Games/UE_<version> on macOS).
-- GenerateClangDatabase compiles without PCH (-NoPCH), but project headers rely on the shared PCH the
-- real build force-includes: each entry gets it back from the module's real-build response files
-- (/FI"..." with MSVC; -include "..." with clang, or the header of -include-pch "X.h.gch").
-- Linux and macOS are untested: no engine for them on the machine this was written on.
local ctx = require('core.context')

local M = {}

local P = ctx.wsl_ue or ctx.ue_unix
local wsl = ctx.wsl_ue ~= nil

local state = {
  running = false, -- generation in progress
  queued = nil,    -- reason for one more generation after the current one
  files = nil,     -- set of lower-case file paths in the database
  tried = {},      -- .cpp files a generation already ran for
  retry = nil,     -- timer of a retry after UBT reported a conflicting instance
  conflicts = 0,
}
local pch_cache = {}
local MAX_CONFLICTS = 6

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'clangd' })
end

local function read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local text = f:read('*a')
  f:close()
  return text
end

local function mtime(path)
  local st = path and vim.uv.fs_stat(path)
  return st and st.mtime.sec or nil
end

--- A path from UBT (D:/x or D:\x in WSL) as a path here (/mnt/d/x).
local function here(path)
  path = path:gsub('\\', '/')
  if not wsl then return path end
  local drive, rest = path:match('^(%a):(.*)$')
  return drive and ('/mnt/' .. drive:lower() .. rest) or path
end

local function key(path)
  return vim.fs.normalize(here(path)):lower()
end

local function db_path()
  return P.root .. '/compile_commands.json'
end

--- Engine root as a path here, or nil.
local function engine_root()
  if state.engine then return state.engine end
  local function valid(dir)
    return dir and vim.uv.fs_stat(dir .. '/Engine/Build/BatchFiles') and vim.fs.normalize(dir) or nil
  end
  local dir = (read(db_path()) or ''):sub(1, 8192):match('"directory"%s*:%s*"([^"]+)"')
  local found = dir and valid(here(dir:gsub('\\\\', '/')):match('^(.*)/Engine/Source/?$'))
    or valid(vim.env.UE_ENGINE_ROOT)
  if not found then
    local ok, proj = pcall(vim.json.decode, read(P.uproject) or '')
    local assoc = ok and type(proj) == 'table' and type(proj.EngineAssociation) == 'string' and proj.EngineAssociation or ''
    if assoc:find('[/\\]') then
      local path = here(assoc)
      found = valid(path:match('^/') and path or (P.root .. '/' .. path))
    elseif wsl then
      local list = read('/mnt/c/ProgramData/Epic/UnrealEngineLauncher/LauncherInstalled.dat')
      local okl, data = pcall(vim.json.decode, list or '')
      for _, inst in ipairs(okl and type(data) == 'table' and data.InstallationList or {}) do
        if inst.AppName == 'UE_' .. assoc then found = valid(here(inst.InstallLocation or '')) end
      end
    elseif assoc ~= '' then
      local ini = vim.fn.has('mac') == 1 and vim.env.HOME .. '/Library/Application Support/Epic/UnrealEngine/Install.ini'
        or vim.env.HOME .. '/.config/Epic/UnrealEngine/Install.ini'
      local want = assoc:gsub('[{}]', ''):lower()
      for k, v in (read(ini) or ''):gmatch('\n%s*([^=\r\n]+)%s*=%s*([^\r\n]+)') do
        local name = vim.trim(k):gsub('[{}]', ''):lower()
        if name == want or name == 'ue_' .. want then found = valid(vim.trim(v)) end
      end
      found = found or valid('/Users/Shared/Epic Games/UE_' .. assoc)
    end
  end
  state.engine = found
  return found
end
M.engine_root = engine_root

local function target()
  local src = P.root .. '/Source'
  local want = P.name .. 'Editor'
  if vim.uv.fs_stat(src .. '/' .. want .. '.Target.cs') then return want end
  local ok, iter = pcall(vim.fs.dir, src)
  for name in ok and iter or function() end do
    local t = name:match('^(.+Editor)%.Target%.cs$')
    if t then return t end
  end
  return want
end

--- UBT command and working directory.
local function command(engine)
  local args = { target(), wsl and 'Win64' or P.platform, 'Development', '-mode=GenerateClangDatabase',
    '-NoExecCodeGenActions' }
  if wsl then
    vim.list_extend(args, { '-project=' .. P.win_root .. '/' .. vim.fs.basename(P.uproject), '-OutputDir=' .. P.win_root })
    table.insert(args, 1, engine .. '/Engine/Binaries/DotNET/UnrealBuildTool/UnrealBuildTool.exe')
  else
    vim.list_extend(args, { '-project=' .. P.uproject, '-OutputDir=' .. P.root })
    table.insert(args, 1, engine .. '/Engine/Build/BatchFiles/' .. P.platform .. '/Build.sh')
  end
  return args, engine .. '/Engine/Source'
end

--- Calls back with why the database needs generating, or nil when it is current. rg lists the inputs
--- off the main loop (without rg only a missing database and the .uproject count).
function M.stale_reason(cb)
  local db = mtime(db_path())
  if not db then return vim.schedule(function() cb('no compile_commands.json') end) end
  local root = P.root
  local function check(files)
    table.insert(files, P.uproject)
    for _, f in ipairs(files) do
      local path = f:sub(1, 1) == '/' and f or (root .. '/' .. f)
      if (mtime(path) or 0) > db then return cb(vim.fs.basename(path) .. ' changed') end
    end
    cb(nil)
  end
  if vim.fn.executable('rg') ~= 1 then return vim.schedule(function() check({}) end) end
  local cmd = { 'rg', '--files', '--no-ignore', '--hidden', '-g', '*.Build.cs', '-g', '*.Target.cs', '-g', '*.uplugin',
    '-g', '!**/Intermediate/**', '-g', '!**/Binaries/**', '-g', '!**/Content/**', '-g', '!**/Saved/**' }
  for _, dir in ipairs({ 'Source', 'Plugins' }) do
    if vim.uv.fs_stat(root .. '/' .. dir) then cmd[#cmd + 1] = dir end
  end
  vim.system(cmd, { cwd = root, text = true }, vim.schedule_wrap(function(res)
    check(vim.split(res.stdout or '', '\r?\n', { trimempty = true }))
  end))
end

local function db_files()
  if not state.files then
    state.files = {}
    local ok, data = pcall(vim.json.decode, read(db_path()) or '')
    for _, e in ipairs(ok and type(data) == 'table' and data or {}) do
      if e.file then state.files[key(e.file)] = true end
    end
  end
  return state.files
end

--- The header the module's real build force-includes as its PCH (UBT path form), from the response
--- files in `dir` (a path here: <...>/<Configuration>/<Module>), other configurations as fallback.
local function pch_for(dir)
  if pch_cache[dir] == nil then
    local found = false
    local rsps = vim.fn.glob(dir .. '/Module.*.rsp', false, true)
    vim.list_extend(rsps, vim.fn.glob(vim.fs.dirname(dir) .. '/../*/' .. vim.fs.basename(dir) .. '/Module.*.rsp', false, true))
    for _, rsp in ipairs(rsps) do
      local text = read(rsp) or ''
      local function try(header)
        if not found and not vim.fs.basename(header):match('^Definitions') and vim.uv.fs_stat(here(header)) then
          found = header
        end
      end
      if wsl then
        for h in text:gmatch('/FI"([^"]+)"') do try(h) end
      else
        for h in text:gmatch('%-include%s+"?([^"%s]+)"?') do try(h) end
        for h in text:gmatch('%-include%-pch%s+"?([^"%s]+)%.[gp]ch"?') do try(h) end
      end
      if found then break end
    end
    pch_cache[dir] = found
  end
  return pch_cache[dir] or nil
end

--- Adds the module's PCH force-include to entries that have none. Returns the number changed.
function M.add_pch()
  local ok, data = pcall(vim.json.decode, read(db_path()) or '')
  if not ok or type(data) ~= 'table' then return 0 end
  local flag = wsl and '/FI"' or '-include "'
  local changed = 0
  for _, e in ipairs(data) do
    local cmd = e.command
    local rsp = type(cmd) == 'string' and (cmd:match('@"([^"]+)"') or cmd:match('@(%S+)'))
    if rsp and not cmd:find(flag, 1, true) then
      local pch = pch_for(vim.fs.dirname(vim.fs.normalize(here(rsp))))
      if pch then
        local at = cmd:find('@', 1, true)
        e.command = cmd:sub(1, at - 1) .. flag .. pch .. '" ' .. cmd:sub(at)
        changed = changed + 1
      end
    end
  end
  if changed > 0 then
    local tmp = db_path() .. '.tmp'
    local f = assert(io.open(tmp, 'wb'))
    f:write(vim.json.encode(data))
    f:close()
    assert(vim.uv.fs_rename(tmp, db_path()))
  end
  return changed
end

local log_path = vim.fn.stdpath('cache') .. '/ue-compiledb.log'

function M.generate(reason)
  if not P then return end
  if state.running or state.retry then
    state.queued = state.queued or reason
    return
  end
  local engine = engine_root()
  if not engine then
    return notify(('compile_commands.json: no Unreal Engine found for %s (set $UE_ENGINE_ROOT)'):format(P.name),
      vim.log.levels.WARN)
  end
  local cmd, cwd = command(engine)
  if vim.fn.executable(cmd[1]) ~= 1 then
    return notify('compile_commands.json: ' .. cmd[1] .. ' not found', vim.log.levels.WARN)
  end
  state.running = true
  local t0 = vim.uv.hrtime()
  notify(('Generating compile_commands.json (%s)'):format(reason))
  vim.system(cmd, { cwd = cwd, text = true }, vim.schedule_wrap(function(res)
    state.running = false
    local output = (res.stdout or '') .. (res.stderr or '')
    local f = io.open(log_path, 'w')
    if f then
      f:write(('$ %s\n(cwd %s, exit %d)\n\n%s'):format(table.concat(cmd, ' '), cwd, res.code, output))
      f:close()
    end
    if res.code == 0 then
      state.conflicts = 0
      state.files, pch_cache = nil, {}
      local ok, err = pcall(M.add_pch)
      if not ok then notify('compile_commands.json: adding PCH failed: ' .. tostring(err), vim.log.levels.WARN) end
      require('ue.compiledb').restart_clangd()
      notify(('compile_commands.json updated (%s, %.0f s)'):format(reason, (vim.uv.hrtime() - t0) / 1e9))
    elseif output:find('ConflictingInstance', 1, true) and state.conflicts < MAX_CONFLICTS then
      -- another UnrealBuildTool (the editor, Windows Neovim) holds UBT's global mutex for a moment
      state.conflicts = state.conflicts + 1
      state.retry = vim.defer_fn(function()
        state.retry = nil
        M.generate(reason)
      end, 10000)
    else
      state.conflicts = 0
      notify(('compile_commands.json update failed (%s), output in %s'):format(reason, log_path), vim.log.levels.WARN)
    end
    local again = state.queued
    state.queued = nil
    if again then M.generate(again) end
  end))
end

local function project_cpp(path)
  local root = P.root:lower() .. '/'
  local p = vim.fs.normalize(path):lower()
  if p:sub(1, #root) ~= root then return false end
  local rel = p:sub(#root + 1)
  return (rel:match('^source/') or rel:match('^plugins/')) and not rel:match('/intermediate/')
    and not rel:match('/thirdparty/') and true or false
end

function M.setup()
  if not P then return end
  local group = vim.api.nvim_create_augroup('ue-compiledb-unix', { clear = true })
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    pattern = { '*.Build.cs', '*.Target.cs', '*.uproject', '*.uplugin' },
    callback = function(ev) M.generate(vim.fs.basename(ev.file) .. ' saved') end,
  })
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufWritePost' }, {
    group = group,
    pattern = '*.cpp',
    callback = function(ev)
      local path = vim.api.nvim_buf_get_name(ev.buf)
      if state.running or state.tried[path:lower()] or not project_cpp(path) then return end
      local db = mtime(db_path())
      if not db or (mtime(path) or 0) <= db or db_files()[key(path)] then return end
      state.tried[path:lower()] = true
      M.generate('new file ' .. vim.fs.basename(path))
    end,
  })
  vim.keymap.set('n', '<leader>bj', function() M.generate('Space bj') end,
    { desc = 'Regenerate compile_commands.json (UBT)' })
  -- startup check, once per session (setup runs again on a config reload)
  if vim.g.ue_compiledb_unix_checked then return end
  vim.g.ue_compiledb_unix_checked = true
  vim.defer_fn(function()
    M.stale_reason(function(reason)
      if reason then return M.generate(reason) end
      if M.add_pch() > 0 then require('ue.compiledb').restart_clangd() end
      -- the project's clangd runs from the start, as in an IDE: class / symbol search works before a
      -- file is open. Its index loads with the first file; with none opened soon, it is asked to load.
      local symbols = require('core.symbols')
      local client = symbols.ensure_clangd()
      vim.defer_fn(function() symbols.load_index(client) end, 3000)
    end)
  end, 1500)
end

return M
