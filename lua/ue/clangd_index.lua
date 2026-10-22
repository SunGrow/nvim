-- clangd threads while the project's background index is (re)built.
--
-- A UE translation unit costs ~45 s CPU and ~1.7 GB RAM per indexing thread (the shared UnrealEd
-- PCH), so building the index of a project takes hours at the usual 8 background threads. While it
-- is incomplete (flag file below, set when the index is started from scratch):
--   * no Unreal process running: 14 threads at normal priority (2-3x faster);
--   * an Unreal editor/game running: 4 threads at background priority, so the editor keeps its RAM
--     (8 threads next to UnrealEditor DebugGame already ran a 31 GB machine out of memory).
-- A UE process starting or ending switches modes by restarting clangd (open files re-parse, ~45 s).
-- Once clangd's background-index progress ends with (nearly) every project file indexed, the flag
-- is removed and clangd goes back to its usual 8 background threads.
local ctx = require('core.context')

local M = {}
M.state = { mode = nil, poll = nil }

local FAST = { j = 14, priority = 'normal' }
local SHARED = { j = 4, priority = 'background' }
local NORMAL = { j = 8, priority = 'background' }
local POLL_MS = 15000

local function flag() return ctx.ue_project_root .. '/.cache/clangd/nvim-index-rebuilding' end

function M.rebuilding() return ctx.is_ue and vim.uv.fs_stat(flag()) ~= nil end

--- Marks the index as being built from scratch (called when it is reset).
function M.mark_rebuilding()
  vim.fn.mkdir(ctx.ue_project_root .. '/.cache/clangd', 'p')
  vim.fn.writefile({ 'clangd index incomplete: nvim runs clangd with more threads until it is built' }, flag())
end

-- Executable names (lowercase, no .exe) that count as a running Unreal process: any UnrealEditor*
-- and the project's own targets (game, server, client builds).
local function ue_prefixes()
  local out = { 'unrealeditor' }
  for _, f in ipairs(vim.fn.glob(ctx.ue_project_root .. '/Source/*.Target.cs', false, true)) do
    out[#out + 1] = vim.fn.fnamemodify(f, ':t'):gsub('%.Target%.cs$', ''):lower()
  end
  return out
end

local function ue_running_in(tasklist)
  local prefixes = M.state.prefixes or ue_prefixes()
  M.state.prefixes = prefixes
  for name in tasklist:gmatch('"([^"]+)%.exe"') do
    local n = name:lower()
    for _, p in ipairs(prefixes) do
      if n:sub(1, #p) == p then return true end
    end
  end
  return false
end

local TASKLIST = { 'tasklist', '/FO', 'CSV', '/NH' }

--- Mode for a clangd starting now (sync process check; only while the index is rebuilt).
function M.mode()
  if not M.rebuilding() then return 'normal' end
  local ok, res = pcall(function() return vim.system(TASKLIST, { text = true }):wait(3000) end)
  local busy = not ok or res.code ~= 0 or ue_running_in(res.stdout or '')
  return busy and 'shared' or 'fast'
end

local MODES = { fast = FAST, shared = SHARED, normal = NORMAL }

--- Puts the mode's thread count and priority into a clangd command (in place) and returns it.
function M.apply(cmd, mode)
  local m = MODES[mode or 'normal']
  for i, a in ipairs(cmd) do
    if a:match('^%-j=') then cmd[i] = '-j=' .. m.j end
    if a:match('^%-%-background%-index%-priority=') then cmd[i] = '--background-index-priority=' .. m.priority end
  end
  return cmd
end

-- Restarts clangd right away. A clangd in the middle of indexing takes 30 s+ to exit when asked
-- (it finishes the files in flight), keeping its RAM while Unreal starts: stop it by force
-- (shards are written atomically) and hide the "quit with exit code 1" warning that causes.
local function restart()
  local clients = vim.lsp.get_clients({ name = 'clangd' })
  if #clients == 0 then return end
  local notify = vim.notify
  vim.notify = function(msg, ...)
    if type(msg) == 'string' and msg:find('^Client clangd quit with exit code') then return end
    return notify(msg, ...)
  end
  local fileless = require('core.symbols').fileless()
  for _, c in ipairs(clients) do c:stop(true) end
  local waited = 0
  local timer = assert(vim.uv.new_timer())
  timer:start(200, 200, vim.schedule_wrap(function()
    waited = waited + 200
    if #vim.lsp.get_clients({ name = 'clangd' }) > 0 and waited < 5000 then return end
    timer:stop()
    timer:close()
    vim.lsp.enable('clangd') -- loaded C++ buffers attach to a new clangd
    require('core.symbols').restart_fileless(fileless)
    vim.defer_fn(function() vim.notify = notify end, 1000)
  end))
end

local function switch(mode, why)
  if mode == M.state.mode then return end
  M.state.mode = mode
  local cfg = vim.lsp.config.clangd
  if not cfg or not cfg.cmd then return end
  vim.lsp.config('clangd', { cmd = M.apply(vim.deepcopy(cfg.cmd), mode) })
  local m = MODES[mode]
  vim.notify(('clangd: %s, now %d %s-priority threads'):format(why, m.j, m.priority), vim.log.levels.INFO, { title = 'clangd index' })
  restart()
end

--- Count of project source files (compile DB entries outside Intermediate/) with an index shard.
function M.coverage()
  local root = ctx.ue_project_root
  local f = io.open(root .. '/compile_commands.json', 'r')
  if not f then return 0, 0 end
  local text = f:read('*a')
  f:close()
  local shards = {}
  for name in vim.fs.dir(root .. '/.cache/clangd/index') do
    local base = name:match('^(.+)%.%x+%.idx$')
    if base then shards[base:lower()] = true end
  end
  local total, done = 0, 0
  for file in text:gmatch('"file"%s*:%s*"([^"]+)"') do
    file = file:gsub('\\\\', '/')
    if not file:find('/Intermediate/', 1, true) then
      total = total + 1
      if shards[vim.fs.basename(file):lower()] then done = done + 1 end
    end
  end
  return done, total
end

--- Ends the rebuild mode when the index covers the project.
function M.check_done()
  if not M.rebuilding() then return end
  local done, total = M.coverage()
  if total == 0 or done < total * 0.98 then return end
  os.remove(flag())
  vim.notify(('clangd index built (%d/%d files)'):format(done, total), vim.log.levels.INFO, { title = 'clangd index' })
  if M.state.poll then M.state.poll:stop() end
  switch('normal', 'index complete')
end

local function poll()
  if not M.rebuilding() then return M.state.poll and M.state.poll:stop() end
  vim.system(TASKLIST, { text = true }, vim.schedule_wrap(function(res)
    if res.code ~= 0 or not M.rebuilding() then return end
    if ue_running_in(res.stdout or '') then
      switch('shared', 'Unreal is running')
    else
      switch('fast', 'no Unreal process')
    end
  end))
end

--- Called just before this config launches an Unreal process: give the RAM back right away.
function M.ue_starting()
  if M.rebuilding() then switch('shared', 'starting Unreal') end
end

--- Called with the mode clangd was configured with at startup (nil on a hot reload: keep it).
function M.setup(mode)
  if mode then M.state.mode = mode end
  vim.api.nvim_create_autocmd('LspProgress', {
    group = vim.api.nvim_create_augroup('ue-clangd-index', { clear = true }),
    pattern = 'end',
    callback = function(ev)
      local client = vim.lsp.get_client_by_id(ev.data.client_id)
      if client and client.name == 'clangd' and M.rebuilding() then
        vim.defer_fn(M.check_done, 2000) -- shards are written right after the last file
      end
    end,
  })
  -- a clangd already running with other threads (config re-applied by a hot reload): restart it
  local running = vim.lsp.get_clients({ name = 'clangd' })[1]
  if mode and running and not vim.tbl_contains(running.config.cmd or {}, '-j=' .. MODES[mode].j) then
    M.state.mode = nil
    switch(mode, 'index ' .. (M.rebuilding() and 'being rebuilt' or 'complete'))
  end
  if not M.rebuilding() then return end
  if not M.state.poll then M.state.poll = vim.uv.new_timer() end
  M.state.poll:start(POLL_MS, POLL_MS, vim.schedule_wrap(poll))
  -- an index finished in an earlier session (or by another Neovim) without this one seeing the end
  vim.defer_fn(M.check_done, 20000)
end

return M
