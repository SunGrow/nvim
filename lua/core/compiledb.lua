-- clangd's compile database for C/C++ projects other than Unreal ones (those: ue/compiledb.lua on
-- Windows, ue/compiledb_unix.lua elsewhere), kept the way IDEs do it.
-- clangd finds <dir>/compile_commands.json and <dir>/build/compile_commands.json in every parent
-- directory of a file by itself (clangd 11+). When neither exists for an opened C/C++ file:
--   * CMake (CMakeLists.txt): configure with CMAKE_EXPORT_COMPILE_COMMANDS=ON, automatically, since
--     configuring builds nothing. In the project's existing build directory (any folder below the
--     project with a CMakeCache.txt of it), else the first configure preset of CMakePresets.json, else
--     build/. Only the Makefile and Ninja generators write the database (CMake docs); a new build/ on
--     Windows uses Ninja (the default Visual Studio generator would ignore the setting).
--     Saving CMakeLists.txt or a *.cmake file configures again (new files, changed flags).
--   * Meson (meson.build): `meson setup build`, automatically; Meson always writes the database into
--     its build directory.
--   * Anything else (Make, autotools): only a build shows the compiler commands. Space bj rebuilds
--     everything under Bear (`bear -- make -B`); never automatic. Until then a notice says so, once.
-- A database in another folder (cmake-build-debug/, out/build/<preset>/, builddir/) reaches clangd as
-- initializationOptions.compilationDatabasePath (M.db_dir, used by lsp.lua): no project file is written.
-- clangd ignores a database that appears while a file is open until it reparses the file, so the clangd
-- clients restart after a generation.
local ctx = require('core.context')

local M = {}

local SOURCE_FT = { c = true, cpp = true, objc = true, objcpp = true, cuda = true }
local SKIP = { ['.git'] = true, ['.cache'] = true, node_modules = true }
local checked = {} -- project roots looked at in this session
local running = {} -- project root -> true while its generator runs

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'compile_commands.json' })
end

local function exists(path) return vim.uv.fs_stat(path) ~= nil end

local function mtime(path)
  local st = vim.uv.fs_stat(path)
  return st and st.mtime.sec or 0
end

local function read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local text = f:read('*a')
  f:close()
  return text
end

local function same_dir(a, b)
  a, b = vim.uv.fs_realpath(a), vim.uv.fs_realpath(b)
  return a ~= nil and a == b
end

--- The directory clangd finds a database in by itself for `path`: compile_commands.json in a parent
--- directory or in its build/.
function M.found(path)
  for dir in vim.fs.parents(path) do
    if exists(dir .. '/compile_commands.json') or exists(dir .. '/build/compile_commands.json') then return dir end
  end
end

--- The outermost directory holding `marker` from `path` up to the repository root (or $HOME).
local function outermost(path, marker)
  local found
  for dir in vim.fs.parents(path) do
    if exists(dir .. '/' .. marker) then found = dir end
    if exists(dir .. '/.git') or dir == vim.env.HOME then break end
  end
  return found
end

--- Project root and kind ('cmake', 'meson', 'make', 'configure') of a source file.
local function project(path)
  local root = outermost(path, 'CMakeLists.txt')
  if root then return root, 'cmake' end
  root = outermost(path, 'meson.build')
  if root then return root, 'meson' end
  for _, name in ipairs({ 'Makefile', 'makefile', 'GNUmakefile' }) do
    root = outermost(path, name)
    if root then return root, 'make' end
  end
  root = outermost(path, 'configure')
  if root then return root, 'configure' end
end

-- top-level folders that hold build trees: build/, build-release/, _build/, builddir/, out/build/<preset>/,
-- cmake-build-debug/ (CLion), .build/; the source tree itself is not walked
local function build_like(name)
  return name:match('^%.?_?build') or name:match('^cmake%-build') or name == 'out' or name == 'builddir'
end

--- Build directories of the project at `root`, newest first: the root itself (in-source build) and
--- build-like folders up to three levels below it.
--- kind 'cmake': folders with a CMakeCache.txt whose source directory is root; 'meson': with meson-info/.
local function build_dirs(root, kind)
  local candidates = { root }
  local ok, iter = pcall(vim.fs.dir, root, {
    depth = 3,
    skip = function(rel) return not SKIP[vim.fs.basename(rel)] and build_like(rel:match('^[^/]+')) ~= nil end,
  })
  if ok then
    for rel, type in iter do
      if type == 'directory' and build_like(rel:match('^[^/]+')) then candidates[#candidates + 1] = root .. '/' .. rel end
    end
  end
  local dirs = {}
  for _, dir in ipairs(candidates) do
    if kind == 'cmake' and exists(dir .. '/CMakeCache.txt') then
      local home = (read(dir .. '/CMakeCache.txt') or ''):match('\nCMAKE_HOME_DIRECTORY:[^=]*=([^\r\n]*)')
      if home and same_dir(home, root) then dirs[#dirs + 1] = dir end
    elseif kind == 'meson' and exists(dir .. '/meson-info') then
      dirs[#dirs + 1] = dir
    end
  end
  table.sort(dirs, function(a, b) return mtime(a) > mtime(b) end)
  return dirs
end

--- For lsp.lua (clangd before_init): the database folder of the project at `root` when clangd would not
--- find it by itself, else nil.
function M.db_dir(root)
  if not root or M.found(root .. '/x') then return nil end
  for _, kind in ipairs({ 'cmake', 'meson' }) do
    for _, dir in ipairs(build_dirs(root, kind)) do
      if exists(dir .. '/compile_commands.json') then return dir end
    end
  end
end

--- A generator is running (statusline "⠋ compile db", core/clangd.lua).
function M.busy() return next(running) ~= nil end

local function restart_clangd()
  require('ue.compiledb').restart_clangd()
end

local log_path = vim.fn.stdpath('cache') .. '/compiledb.log'

--- Runs a generator; on success restarts clangd if the database changed. `db` is where it is written.
local function run(root, cmd, db, reason, on_done)
  if running[root] then return end
  if vim.fn.executable(cmd[1]) ~= 1 then
    return notify(('%s is not installed: no compile_commands.json for %s'):format(cmd[1], vim.fs.basename(root)),
      vim.log.levels.WARN)
  end
  running[root] = true
  local before = read(db)
  local t0 = vim.uv.hrtime()
  notify(('%s: %s (%s)'):format(vim.fs.basename(root),
    (table.concat(cmd, ' '):gsub(vim.pesc(root), '.')), reason))
  vim.system(cmd, { cwd = root, text = true }, vim.schedule_wrap(function(res)
    running[root] = nil
    local f = io.open(log_path, 'w')
    if f then
      f:write(('$ %s\n(cwd %s, exit %d)\n\n%s\n%s'):format(table.concat(cmd, ' '), root, res.code, res.stdout or '', res.stderr or ''))
      f:close()
    end
    local after = read(db)
    if res.code ~= 0 and not after then
      return notify(('%s failed (exit %d), output in %s'):format(cmd[1], res.code, log_path), vim.log.levels.WARN)
    end
    if after and after ~= before then
      notify(('%s updated (%.1f s)%s'):format(vim.fn.fnamemodify(db, ':~:.'), (vim.uv.hrtime() - t0) / 1e9,
        res.code ~= 0 and (', with errors: ' .. log_path) or ''))
      restart_clangd()
    end
    if on_done then on_done() end
  end))
end

--- First configure preset of CMakePresets.json / CMakeUserPresets.json (cmake --list-presets).
local function cmake_preset(root)
  if not (exists(root .. '/CMakePresets.json') or exists(root .. '/CMakeUserPresets.json')) then return nil end
  local res = vim.system({ 'cmake', '--list-presets=configure' }, { cwd = root, text = true }):wait()
  return (res.stdout or ''):match('\n%s+"([^"]+)"')
end

--- Configures the CMake project at `root` with the database export on.
local function cmake(root, reason)
  local export = '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON'
  local dir = build_dirs(root, 'cmake')[1]
  if dir then
    local gen = (read(dir .. '/CMakeCache.txt') or ''):match('\nCMAKE_GENERATOR:[^=]*=([^\r\n]*)') or ''
    if gen ~= '' and not (gen:find('Makefiles', 1, true) or gen:find('Ninja', 1, true)) then
      return notify(('%s uses the %s generator, which writes no compile_commands.json; configure a Ninja or Makefile build folder')
        :format(vim.fn.fnamemodify(dir, ':~:.'), gen), vim.log.levels.WARN)
    end
    return run(root, { 'cmake', '-S', root, '-B', dir, export }, dir .. '/compile_commands.json', reason)
  end
  local preset = vim.fn.executable('cmake') == 1 and cmake_preset(root)
  if preset then
    -- the preset's binaryDir is known only after configuring: look for the new build folder then
    return run(root, { 'cmake', '--preset', preset, export }, root .. '/.no-db', reason, function()
      local new = build_dirs(root, 'cmake')[1]
      if new and exists(new .. '/compile_commands.json') then
        notify(('preset %s configured in %s'):format(preset, vim.fn.fnamemodify(new, ':~:.')))
        restart_clangd()
      end
    end)
  end
  local cmd = { 'cmake', '-S', root, '-B', root .. '/build', export }
  if vim.fn.has('win32') == 1 then
    if vim.fn.executable('ninja') ~= 1 then
      return notify('CMake on Windows writes compile_commands.json only with Ninja (not installed)', vim.log.levels.WARN)
    end
    vim.list_extend(cmd, { '-G', 'Ninja' })
  end
  run(root, cmd, root .. '/build/compile_commands.json', reason)
end

local function meson(root, reason)
  local dir = build_dirs(root, 'meson')[1]
  if dir then
    return run(root, { 'meson', 'setup', '--reconfigure', dir }, dir .. '/compile_commands.json', reason)
  end
  run(root, { 'meson', 'setup', 'build' }, root .. '/build/compile_commands.json', reason)
end

--- Space bj in a Make (or other) project: a full rebuild under Bear records every compile command.
local function bear(root, reason)
  if vim.fn.executable('bear') ~= 1 then
    local how = vim.fn.has('mac') == 1 and 'brew install bear' or 'sudo apt install bear (or your package manager)'
    return notify('Bear is not installed: ' .. how, vim.log.levels.WARN)
  end
  local jobs = '-j' .. ((vim.uv.available_parallelism and vim.uv.available_parallelism()) or 4)
  run(root, { 'bear', '--', 'make', '-B', '-k', jobs }, root .. '/compile_commands.json', reason)
end

--- Generates (or updates) the database of the project the file at `path` belongs to.
--- manual: Space bj (Bear may build); otherwise only the steps that build nothing run.
function M.generate(path, reason, manual)
  local root, kind = project(path)
  if not root then
    return manual and notify('No CMakeLists.txt, meson.build or Makefile above ' .. vim.fn.fnamemodify(path, ':~:.'),
      vim.log.levels.WARN)
  end
  if kind == 'cmake' then return cmake(root, reason) end
  if kind == 'meson' then return meson(root, reason) end
  if kind == 'configure' then
    return notify(vim.fs.basename(root) .. ': run ./configure first, then Space bj records a build with Bear',
      vim.log.levels.WARN)
  end
  if manual then return bear(root, reason) end
  notify(('No compile_commands.json for %s: clangd guesses the flags. Space bj rebuilds it under Bear to record them.')
    :format(vim.fs.basename(root)))
end

--- A C/C++ file was opened: generate what clangd lacks, once per project and session.
function M.check(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  if path == '' or vim.bo[buf].buftype ~= '' or M.found(path) then return end
  local root, kind = project(path)
  if not root or checked[root] then return end
  checked[root] = true
  -- a database clangd does not look for (cmake-build-debug/...) already reaches it through lsp.lua
  if (kind == 'cmake' or kind == 'meson') and M.db_dir(root) then return end
  M.generate(path, 'no compile_commands.json', false)
end

function M.setup()
  if ctx.is_ue then return end -- ue/compiledb.lua
  if ctx.wsl_ue or ctx.ue_unix then return require('ue.compiledb_unix').setup() end
  local group = vim.api.nvim_create_augroup('core-compiledb', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = vim.tbl_keys(SOURCE_FT),
    callback = function(ev) vim.schedule(function() M.check(ev.buf) end) end,
  })
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    pattern = { 'CMakeLists.txt', '*.cmake', 'meson.build', 'meson.options', 'meson_options.txt' },
    callback = function(ev)
      local file = vim.api.nvim_buf_get_name(ev.buf) -- absolute (ev.file can be relative)
      local root, kind = project(file)
      if (kind == 'cmake' or kind == 'meson') and #build_dirs(root, kind) > 0 then
        M.generate(file, vim.fs.basename(file) .. ' saved', false)
      end
    end,
  })
  vim.keymap.set('n', '<leader>bj', function()
    local path = vim.api.nvim_buf_get_name(0)
    M.generate(path ~= '' and path or (vim.fn.getcwd() .. '/x'), 'Space bj', true)
  end, { desc = 'Generate compile_commands.json (CMake / Meson / Bear)' })
end

return M
