-- clangd's compile database for Unreal projects, kept current without manual steps (like Rider).
--
-- UBT GenerateClangDatabase (`:UBT gen_compile_db`) writes <project>/compile_commands.json. It runs
-- by itself when:
--   * the database is missing, or older than the .uproject / *.uplugin / *.Build.cs / *.Target.cs
--     files (checked at startup),
--   * one of those files is saved,
--   * a project .cpp that the database does not list is opened or saved (new files).
-- UBT generates the database with -NoPCH (GenerateClangDatabase.cs), but project headers rely on the
-- shared PCH the real build force-includes, so every entry gets the same /FI as the module's unity
-- build (read from its Module.*.cpp.obj.rsp). Then the clangd clients restart.
-- It uses UBT's preset_target (Development Editor), so the per-file response files it writes do not
-- replace the ones of the DebugGame build the run configurations use by default.
local ctx = require('core.context')

local M = {}

local state = {
  running = false, -- generation in progress
  queued = nil,    -- reason for one more generation after the current one
  files = nil,     -- set of lower-case file paths in the database
  tried = {},      -- .cpp files a generation already ran for (UBT may not compile every .cpp)
  waiting = nil,   -- timer waiting for a running UBT job (build) to end
  retry = nil,     -- timer of a retry after UBT reported a conflicting instance
  conflicts = 0,   -- retries so far
}
local pch_cache = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'clangd' })
end

local function db_path()
  return ctx.ue_project_root .. '/compile_commands.json'
end

local function read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local text = f:read('*a')
  f:close()
  return text
end

local function mtime(path)
  local st = vim.uv.fs_stat(path)
  return st and st.mtime.sec or nil
end

local function key(path)
  return vim.fs.normalize(path):lower()
end

--- Calls back (on the main loop) with why the database needs generating, or nil when it is current.
--- The inputs are the files whose change alters modules, include paths or defines; rg finds them
--- off the main loop (a vim.fn.glob over Plugins/ blocks for 0.3-0.5 s).
function M.stale_reason(cb)
  local db = mtime(db_path())
  if not db then return vim.schedule(function() cb('no compile_commands.json') end) end
  local root = ctx.ue_project_root
  local cmd = { 'rg', '--files', '--no-ignore', '--hidden', '-g', '*.Build.cs', '-g', '*.Target.cs', '-g', '*.uplugin',
    '-g', '!**/Intermediate/**', '-g', '!**/Binaries/**', '-g', '!**/Content/**', '-g', '!**/Saved/**' }
  for _, dir in ipairs({ 'Source', 'Plugins' }) do
    if vim.uv.fs_stat(root .. '/' .. dir) then cmd[#cmd + 1] = dir end
  end
  vim.system(cmd, { cwd = root, text = true }, vim.schedule_wrap(function(res)
    local files = vim.split(res.stdout or '', '\r?\n', { trimempty = true })
    vim.list_extend(files, vim.fn.glob(root .. '/*.uproject', false, true))
    for _, f in ipairs(files) do
      local path = vim.fs.normalize(f):match('^%a:') and f or (root .. '/' .. f)
      if (mtime(path) or 0) > db then return cb(vim.fs.basename(path) .. ' changed') end
    end
    cb(nil)
  end))
end

local function db_files()
  if not state.files then
    state.files = {}
    local ok, data = pcall(vim.json.decode, read(db_path()) or '')
    if ok and type(data) == 'table' then
      for _, e in ipairs(data) do
        if e.file then state.files[key(e.file)] = true end
      end
    end
  end
  return state.files
end

--- The precompiled header the real build force-includes for the module whose intermediate
--- directory is `dir` (<...>/x64/UnrealEditor/<Configuration>/<Module>); other configurations'
--- builds of the module are the fallback.
local function pch_for(dir)
  if pch_cache[dir] == nil then
    local found = false
    local rsps = vim.fn.glob(dir .. '/Module.*.cpp.obj.rsp', false, true)
    vim.list_extend(rsps, vim.fn.glob(vim.fs.dirname(dir) .. '/../*/' .. vim.fs.basename(dir) .. '/Module.*.cpp.obj.rsp', false, true))
    for _, rsp in ipairs(rsps) do
      for fi in (read(rsp) or ''):gmatch('/FI"([^"]+)"') do
        if not vim.fs.basename(fi):match('^Definitions') and vim.uv.fs_stat(fi) then
          found = fi
          break
        end
      end
      if found then break end
    end
    pch_cache[dir] = found
  end
  return pch_cache[dir] or nil
end

--- Adds the module's PCH force-include to entries that have none. Returns the number changed.
function M.add_pch()
  local text = read(db_path())
  local ok, data = pcall(vim.json.decode, text or '')
  if not ok or type(data) ~= 'table' then return 0 end
  local changed = 0
  for _, e in ipairs(data) do
    local cmd = e.command
    local rsp = type(cmd) == 'string' and cmd:match('@"([^"]+)"')
    if rsp and not cmd:find('/FI"', 1, true) then
      local pch = pch_for(vim.fs.dirname(vim.fs.normalize(rsp)))
      if pch then
        local at = cmd:find('@"', 1, true)
        e.command = cmd:sub(1, at - 1) .. '/FI"' .. pch .. '" ' .. cmd:sub(at)
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

--- Restarts the project clangd so it reloads the database (open C++ buffers re-attach).
local function restart_clangd()
  local clients = vim.lsp.get_clients({ name = 'clangd' })
  if #clients == 0 then return end
  for _, c in ipairs(clients) do c:stop() end
  local waited = 0
  local timer = assert(vim.uv.new_timer())
  timer:start(100, 100, vim.schedule_wrap(function()
    waited = waited + 100
    local left = vim.lsp.get_clients({ name = 'clangd' })
    if #left > 0 and waited < 5000 then return end
    timer:stop()
    timer:close()
    for _, c in ipairs(left) do c:stop(true) end
    vim.lsp.enable('clangd') -- runs the FileType autocmds of loaded buffers: they attach to a new clangd
  end))
end

local function finished()
  state.files = nil
  pch_cache = {}
  local ok, err = pcall(M.add_pch)
  if not ok then notify('compile_commands.json: adding PCH failed: ' .. tostring(err), vim.log.levels.WARN) end
  restart_clangd()
end

local MAX_CONFLICTS = 6

--- The last UBT job failed because another UnrealBuildTool instance was running.
local function conflicting_instance()
  local ok, path = pcall(function() return require('UBT.path').get_progress_log_file_path() end)
  return ok and (read(path) or ''):find('ConflictingInstance', 1, true) ~= nil
end

local function ubt_busy()
  local ok, runner = pcall(require, 'UBT.job.runner')
  return ok and runner.is_running()
end

--- Generates the database now, or after the running UBT job (a build) ends.
--- UBT.nvim runs one job at a time and starting one stops the other.
function M.generate(reason)
  if not ctx.is_ue then return end
  if state.running or state.retry then
    state.queued = state.queued or reason
    return
  end
  require('lazy').load({ plugins = { 'UBT.nvim' } })
  if ubt_busy() then
    state.queued = state.queued or reason
    if not state.waiting then
      state.waiting = assert(vim.uv.new_timer())
      state.waiting:start(2000, 2000, vim.schedule_wrap(function()
        if ubt_busy() then return end
        state.waiting:stop()
        state.waiting:close()
        state.waiting = nil
        local r = state.queued
        state.queued = nil
        M.generate(r)
      end))
    end
    return
  end
  state.running = true
  vim.cmd.redrawstatus()
  require('UBT.api').gen_compile_db({
    on_complete = function(result)
      state.running = false
      if result and result.success then
        state.conflicts = 0
        finished()
        notify(('compile_commands.json updated (%s, %ds)'):format(reason, result.elapsed_s or 0))
      elseif conflicting_instance() and state.conflicts < MAX_CONFLICTS then
        -- Another UnrealBuildTool (the editor, another Neovim) holds UBT's global mutex for a moment.
        state.conflicts = state.conflicts + 1
        state.retry = vim.defer_fn(function()
          state.retry = nil
          M.generate(reason)
        end, 10000)
      else
        state.conflicts = 0
        notify('compile_commands.json update failed (' .. reason .. ') - :UBT log has the output', vim.log.levels.WARN)
      end
      vim.cmd.redrawstatus()
      local again = state.queued
      state.queued = nil
      if again then M.generate(again) end
    end,
  })
end

--- A UBT job of ours is running (builds wait for it).
function M.running()
  return state.running
end

--- Running or about to retry (statusline).
function M.busy()
  return state.running or state.retry ~= nil
end

--- After a successful build: modules built for the first time now have their PCH response files.
function M.after_build()
  if state.running or not mtime(db_path()) then return end
  pch_cache = {}
  if M.add_pch() > 0 then restart_clangd() end
end

local function project_cpp(path)
  local root = key(ctx.ue_project_root) .. '/'
  local p = key(path)
  if p:sub(1, #root) ~= root then return false end
  local rel = p:sub(#root + 1)
  return (rel:match('^source/') or rel:match('^plugins/')) and not rel:match('/intermediate/')
    and not rel:match('/thirdparty/') and true or false
end

function M.setup()
  if not ctx.is_ue or state.setup then return end
  state.setup = true
  local group = vim.api.nvim_create_augroup('ue-compiledb', { clear = true })
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
      if state.running or state.tried[key(path)] or not project_cpp(path) then return end
      -- Only files created after the database: files of disabled plugins or other platforms are
      -- never in it, and regenerating would not add them.
      local db = mtime(db_path())
      if not db or (mtime(path) or 0) <= db or db_files()[key(path)] then return end
      state.tried[key(path)] = true
      M.generate('new file ' .. vim.fs.basename(path))
    end,
  })
  -- Startup check, after the UI is up.
  vim.defer_fn(function()
    M.stale_reason(function(reason)
      if reason then return M.generate(reason) end
      if M.add_pch() > 0 then restart_clangd() end
    end)
  end, 1500)
end

return M
