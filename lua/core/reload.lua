-- Config hot reload: saving (or syncing) a file of this config applies it to the running Neovim.
--
-- The config folder is watched (libuv fs_event: recursive, per folder on Linux); changes are applied
-- 300 ms after the last one, so a git pull of many files is one reload:
--   * lua/core/*, lua/ue/* modules: re-required and patched into the table already loaded, so code
--     holding a reference (`local cdb = require('ue.compiledb')`) gets the new functions. Then the
--     module's `on_reload(old)` runs if it has one, else its `setup()` (all setups here are
--     idempotent: augroups with clear = true, named dap listeners).
--   * core.options / core.keymaps / core.autocmds: run again.
--   * lua/plugins/*.lua: lazy.nvim re-reads the specs; for each plugin of the changed file its keys
--     are re-mapped (stale ones removed) and, if it is loaded, its `config` runs again. Not while a
--     debug session runs for the dap plugins (applied after it ends).
--   * colors/<name>.lua: re-applied when it is the current color scheme.
--   * init.lua, core/lazy.lua: need a restart (said so). tools/*: the debug adapter is started per
--     session (next session uses it); ue-lsp needs :LspRestart ue_ls.
-- :ConfigReload reloads every loaded config module and every plugin spec by hand.
local M = {}

local root = vim.fs.normalize(vim.fn.stdpath('config'))
local RESTART = { ['init.lua'] = true, ['lua/core/lazy.lua'] = true }
local RERUN = { ['core.options'] = true, ['core.keymaps'] = true, ['core.autocmds'] = true }
local DAP_PLUGINS = { ['nvim-dap'] = true, ['nvim-dap-ui'] = true, ['nvim-dap-virtual-text'] = true, ['UDB.nvim'] = true }

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'Config reload' })
end

local function modname(rel)
  local m = rel:match('^lua/(.+)%.lua$')
  return m and (m:gsub('/', '.'):gsub('%.init$', ''))
end

--- Re-requires a loaded module and patches the old table in place. Returns ok, message.
function M.reload_module(mod)
  local old = package.loaded[mod]
  if old == nil then return true, nil end -- not loaded: the next require reads the new file
  package.loaded[mod] = nil
  local ok, new = pcall(require, mod)
  if not ok then
    package.loaded[mod] = old
    return false, mod .. ': ' .. tostring(new)
  end
  if RERUN[mod] then return true, mod .. ' (re-run)' end
  if type(old) == 'table' and type(new) == 'table' and old ~= new then
    -- runtime state a module keeps in M.state survives (module-local variables start fresh)
    if type(old.state) == 'table' and type(new.state) == 'table' then new.state = old.state end
    for k in pairs(old) do
      if new[k] == nil then old[k] = nil end
    end
    for k, v in pairs(new) do old[k] = v end
    package.loaded[mod] = old
    new = old
  end
  local hook = type(new) == 'table' and (new.on_reload or new.setup)
  if hook then
    local hok, err = pcall(hook)
    if not hok then return false, mod .. ' reloaded, but ' .. (new.on_reload and 'on_reload' or 'setup') .. ' failed: ' .. tostring(err) end
    return true, mod .. (new.on_reload and ' (on_reload)' or ' (setup)')
  end
  return true, mod
end

local deferred -- spec modules whose dap plugin configs wait for the end of the debug session

--- Re-reads lazy.nvim's specs and re-applies the plugins defined in the given spec modules
--- (all plugins when `mods` is nil). Returns the list of messages and whether one failed.
function M.reload_specs(mods)
  local Config = require('lazy.core.config')
  local Plugin = require('lazy.core.plugin')
  local Handler = require('lazy.core.handler')
  local Loader = require('lazy.core.loader')
  local Fragments = require('lazy.core.fragments')
  local Keys = require('lazy.core.handler.keys')

  -- old key mappings per plugin, to remove the ones a spec no longer has
  local old_keys = {}
  for name, p in pairs(Config.plugins) do
    old_keys[name] = p._.handlers and p._.handlers.keys or {}
  end

  -- which plugins each spec module defines (lazy does not record it)
  local defined = {}
  local add = Fragments.add
  Fragments.add = function(self, spec)
    local frag = add(self, spec)
    local importing = self.spec and self.spec.importing
    if frag and frag.name and importing and (not mods or mods[importing]) then defined[frag.name] = true end
    return frag
  end
  local ok, err = pcall(Plugin.load)
  Fragments.add = add
  if not ok then return { 'lazy spec reload failed: ' .. tostring(err) }, true end

  local msgs, failed = {}, false
  local in_session = package.loaded['dap'] and require('dap').session() ~= nil
  for name in pairs(defined) do
    local p = Config.plugins[name]
    if p then
      -- keys: drop the old lazy-loading stubs / mappings and add the new ones. Plugin.load copied the
      -- old state (`_`) onto the new spec, including the cache of resolved keys/opts: clear it.
      Handler.disable(p)
      p._.cache = nil
      p._.handlers = nil
      Handler.resolve(p)
      local new_keys = p._.handlers.keys or {}
      for id, k in pairs(old_keys[name] or {}) do
        if not new_keys[id] then pcall(vim.keymap.del, k.mode, k.lhs) end
      end
      local has_keys = next(new_keys) ~= nil or next(old_keys[name] or {}) ~= nil
      local has_config = p.config ~= nil or p.opts ~= nil
      local what = {}
      if has_keys then what[#what + 1] = 'keys' end
      if p._.loaded then
        for _, k in pairs(new_keys) do
          if k.rhs then vim.keymap.set(k.mode, k.lhs, k.rhs, Keys.opts(k)) end
        end
        if has_config and in_session and DAP_PLUGINS[name] then
          M.after_session(mods)
          what[#what + 1] = 'config after the debug session'
        elseif has_config then
          local cok, cerr = pcall(Loader.config, p) -- lazy reports errors in config itself
          if not cok then failed = true end
          what[#what + 1] = cok and 'config' or ('config failed: ' .. tostring(cerr))
        end
      else
        Handler.enable(p)
        if has_config then what[#what + 1] = 'config when it loads' end
      end
      if #what > 0 then msgs[#msgs + 1] = name .. ' (' .. table.concat(what, ', ') .. ')' end
    end
  end
  return msgs, failed
end

--- Re-applies the deferred spec modules once the debug session ends.
function M.after_session(mods)
  deferred = vim.tbl_extend('force', deferred or {}, mods or {})
  local dap = require('dap')
  dap.listeners.after.event_terminated['core-reload'] = function()
    local todo = deferred
    deferred = nil
    dap.listeners.after.event_terminated['core-reload'] = nil
    vim.schedule(function()
      local msgs = M.reload_specs(todo)
      notify('Applied after the debug session:\n  ' .. table.concat(msgs, '\n  '))
    end)
  end
end

--- Applies a set of changed files (paths relative to the config folder, forward slashes).
function M.apply(files)
  local msgs, failed, specs, later = {}, false, nil, {}
  local function add(ok, msg)
    if msg then msgs[#msgs + 1] = (ok and '✓ ' or '󰅖 ') .. msg end
    if not ok then failed = true end
  end
  local sorted = vim.tbl_keys(files)
  table.sort(sorted)
  for _, rel in ipairs(sorted) do
    local mod = modname(rel)
    if RESTART[rel] then
      later[#later + 1] = rel .. ': restart Neovim to apply'
    elseif mod and mod:match('^plugins%.') then
      specs = specs or {}
      specs[mod] = true
    elseif mod then
      add(M.reload_module(mod))
    elseif rel:match('^colors/.+%.lua$') then
      local scheme = vim.fn.fnamemodify(rel, ':t:r')
      if vim.g.colors_name == scheme then add(pcall(vim.cmd.colorscheme, scheme) and true, 'colorscheme ' .. scheme) end
    elseif rel:match('^tools/dbgeng%-dap/') then
      later[#later + 1] = 'dbgeng-dap: used from the next debug session'
    elseif rel:match('^tools/ue%-lsp/') then
      later[#later + 1] = 'ue-lsp: :LspRestart ue_ls to apply'
    end
    if rel == 'lua/plugins/lsp.lua' then
      later[#later + 1] = 'LSP settings: running servers keep the old ones until :LspRestart'
    end
  end
  if specs then
    local spec_msgs, spec_failed = M.reload_specs(specs)
    for _, m in ipairs(spec_msgs) do add(not spec_failed or not m:find('failed'), m) end
  end
  if #msgs == 0 and #later == 0 then return end
  vim.list_extend(msgs, later)
  notify('Reloaded:\n' .. table.concat(vim.tbl_map(function(m) return '  ' .. m end, msgs), '\n'),
    failed and vim.log.levels.ERROR or vim.log.levels.INFO)
end

--- :ConfigReload — every loaded config module and every plugin spec.
function M.reload_all()
  local files = {}
  for mod in pairs(package.loaded) do
    if mod:match('^core%.') or mod:match('^ue%.') then
      local rel = 'lua/' .. mod:gsub('%.', '/') .. '.lua'
      if mod ~= 'core.lazy' and mod ~= 'core.reload' and vim.uv.fs_stat(root .. '/' .. rel) then files[rel] = true end
    end
  end
  for name in vim.fs.dir(root .. '/lua/plugins') do
    if name:match('%.lua$') then files['lua/plugins/' .. name] = true end
  end
  if vim.g.colors_name and vim.uv.fs_stat(root .. '/colors/' .. vim.g.colors_name .. '.lua') then
    files['colors/' .. vim.g.colors_name .. '.lua'] = true
  end
  M.apply(files)
end

-- watcher -----------------------------------------------------------------------------------------
local pending = {}

local function on_change(err, filename, prefix)
  if err or not filename then return end
  local rel = (prefix or '') .. filename:gsub('\\', '/')
  if rel:match('^%.git/') or rel:match('/%.git/') then return end
  if not (rel:match('%.lua$') or rel:match('^tools/.+%.py$') or rel:match('^tools/.+%.js$')) then return end
  pending[rel] = true
  M._timer:stop()
  M._timer:start(300, 0, vim.schedule_wrap(function()
    local files = pending
    pending = {}
    -- skip files that did not really change (editors and git touch files without changing them). On
    -- Windows libuv also reports reads (FILE_NOTIFY_CHANGE_LAST_ACCESS): lazy.nvim reading a spec or
    -- python loading the debug adapter fired a bogus "Reloaded". A file not seen before counts as
    -- changed only when it was written after the watcher started.
    for rel2 in pairs(files) do
      local st = vim.uv.fs_stat(root .. '/' .. rel2)
      local key = st and (st.size .. ':' .. st.mtime.sec .. ':' .. st.mtime.nsec)
      local unchanged = st and (M._seen[rel2] == key or (M._seen[rel2] == nil and st.mtime.sec < M._started))
      if unchanged then files[rel2] = nil end
      M._seen[rel2] = key
    end
    if next(files) then M.apply(files) end
  end))
end

function M.setup()
  if #vim.api.nvim_list_uis() == 0 and not vim.g.config_reload_headless then return end -- not in scripts
  for _, w in ipairs(M._watches or {}) do w:stop() end
  M._watches = {}
  M._seen = M._seen or {}
  M._started = M._started or os.time()
  M._timer = M._timer or vim.uv.new_timer()
  -- Windows and macOS watch a tree; Linux (WSL) inotify accepts the recursive flag but watches only
  -- the folder itself, so there every folder gets its own watcher (folders made later: :ConfigReload)
  local linux = vim.fn.has('linux') == 1
  local dirs = { '' }
  if linux then
    local skip = function(d) return d ~= '.git' and d ~= '__pycache__' end
    for name, type in vim.fs.dir(root, { depth = 6, skip = skip }) do
      if type == 'directory' and name ~= '.git' and not name:match('__pycache__') then
        dirs[#dirs + 1] = name .. '/'
      end
    end
  end
  for _, dir in ipairs(dirs) do
    local w = vim.uv.new_fs_event()
    local ok, err = w:start(root .. '/' .. dir, { recursive = not linux }, function(e, f) on_change(e, f, dir) end)
    if ok then
      M._watches[#M._watches + 1] = w
    elseif dir == '' then
      notify('cannot watch ' .. root .. ': ' .. tostring(err), vim.log.levels.WARN)
    end
  end
  vim.api.nvim_create_user_command('ConfigReload', function() M.reload_all() end,
    { desc = 'Reload this Neovim config (modules, plugin specs, color scheme)' })
end

M.on_reload = M.setup

return M
