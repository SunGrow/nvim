-- Shadow copies of UHT's *.generated.h for clangd, in Unreal projects (Windows, and WSL in a Windows
-- project).
--
-- GENERATED_BODY(), UCLASS(), VINTERFACES() and the dynamic delegate macros expand to
-- FID_<file>_h_<__LINE__>_<suffix> (ObjectMacros.h, DelegateCombinations.h). UHT defines those in
-- X.generated.h only for the lines it saw at the last build, so a line added or removed above them broke
-- the expansion until the next build: clangd reported "A type specifier is required for all declarations"
-- on GENERATED_BODY and "Call to deleted constructor" on the class; Rider shows nothing.
--
-- Each shadow includes the real header and defines the same macros for the lines around each one, as
-- aliases of the nearest real one. clangd reads the shadows first: .clangd adds `/clang:-iquote<dir>`,
-- searched for "X.generated.h" before UBT's /I folders (tested with clangd 20 in clang-cl mode).
-- Names found in two modules get no shadow (the real one is used).
--
-- The scan runs as a separate `nvim -l` job (this file with --job): from WSL, reading and writing ~1000
-- files on /mnt/d took two minutes, which on Neovim's own loop stalled typing.

local M = {}

local job_roots -- { root, win_root } in the job process, which has no config (core.context)

-- macros the source writes, keyed by line; the rest of the generated macros use fixed line numbers
local SUFFIXES = { GENERATED_BODY = true, GENERATED_BODY_LEGACY = true, PROLOG = true, VINTERFACES = true, DELEGATE = true }
local WINDOW = 80 -- lines a macro may move before the next build regenerates the header
local HEADER = '// Made by Neovim (lua/ue/uht_shadow.lua) for clangd; rewritten when the header below changes.'
local VERSION = '2' -- of the shadow text: a change rewrites every shadow

--- Project root here and as clangd.exe sees it (Windows path).
local function roots()
  if job_roots then return job_roots[1], job_roots[2] end
  local ctx = require('core.context')
  if ctx.is_ue then return ctx.ue_project_root, ctx.ue_project_root end
  if ctx.wsl_ue then return ctx.wsl_ue.root, ctx.wsl_ue.win_root end
end

--- Shadow folder; `as_clangd`: the path clangd sees.
function M.dir(as_clangd)
  local root, win_root = roots()
  if not root then return nil end
  return (as_clangd and win_root or root) .. '/Intermediate/ClangdUHT'
end

--- The .clangd flag that puts the shadows first.
function M.clangd_flag()
  local dir = M.dir(true)
  return dir and ('"/clang:-iquote' .. dir .. '"') or nil
end

local function read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end

local function mtime(path)
  local st = vim.uv.fs_stat(path)
  return st and st.mtime.sec * 1e9 + st.mtime.nsec or nil
end

--- Shadow text for a generated header (nil when it has no line-keyed macros).
function M.shadow_text(text, include_path)
  local groups, order = {}, {}
  for name in text:gmatch('\n#define (FID_[%w_]+)') do
    local prefix, line, suffix = name:match('^(.*_h_)(%d+)_(.+)$')
    if prefix and SUFFIXES[suffix] then
      local key = prefix .. '\0' .. suffix
      if not groups[key] then
        groups[key] = { prefix = prefix, suffix = suffix, lines = {}, defined = {} }
        order[#order + 1] = key
      end
      local g = groups[key]
      local n = tonumber(line)
      if not g.defined[n] then
        g.defined[n] = true
        g.lines[#g.lines + 1] = n
      end
    end
  end
  if #order == 0 then return nil end
  -- export: the include in X.h counts as used for the macros of the real header (clangd's unused-includes)
  local out = { HEADER, '#pragma once', ('#include "%s" // IWYU pragma: export'):format(include_path) }
  for _, key in ipairs(order) do
    local g = groups[key]
    table.sort(g.lines)
    local first, last = math.max(1, g.lines[1] - WINDOW), g.lines[#g.lines] + WINDOW
    for n = first, last do
      if not g.defined[n] then
        local best, dist = nil, math.huge
        for _, l in ipairs(g.lines) do
          if math.abs(n - l) < dist then best, dist = l, math.abs(n - l) end
        end
        if dist <= WINDOW then
          out[#out + 1] = ('#define %s%d_%s %s%d_%s'):format(g.prefix, n, g.suffix, g.prefix, best, g.suffix)
        end
      end
    end
  end
  out[#out + 1] = ''
  return table.concat(out, '\n')
end

--- The project's UHT headers (the Editor target's, which the compile database uses): name -> path,
--- without names found in two modules.
local function scan()
  local root = roots()
  local found, dup = {}, {}
  local tail = '/Intermediate/Build/Win64/UnrealEditor/Inc/*/UHT/*.generated.h'
  for _, pattern in ipairs({ root .. tail, root .. '/Plugins/*' .. tail, root .. '/Plugins/*/*' .. tail }) do
    for _, path in ipairs(vim.fn.glob(pattern, true, true)) do
      path = vim.fs.normalize(path)
      local name = vim.fs.basename(path)
      if found[name] and found[name] ~= path then dup[name] = true end
      found[name] = path
    end
  end
  for name in pairs(dup) do found[name] = nil end
  return found, dup
end

M.headers = {} -- name -> real path, from the last scan

--- Write the shadow of `name` when its real header is newer (or `force`); true if written.
local function update(name, path, force)
  local root, win_root = roots()
  local dir = M.dir()
  local shadow = dir .. '/' .. name
  local real_time, shadow_time = mtime(path), mtime(shadow)
  if not real_time or (not force and shadow_time and shadow_time >= real_time) then return false end
  local text = read(path)
  if not text then return false end
  local include = win_root .. path:sub(#root + 1)
  local new = M.shadow_text(text, include)
  if not new then
    if shadow_time then os.remove(shadow) end
    return false
  end
  if read(shadow) == new then
    vim.uv.fs_utime(shadow, os.time(), os.time()) -- up to date: mark it newer than the real one
    return false
  end
  vim.fn.mkdir(dir, 'p')
  local f = io.open(shadow, 'wb')
  if not f then return false end
  f:write(new)
  f:close()
  return true
end

--- In the job process: bring every shadow up to date; prints { headers = name -> path, written = n }.
function M.job(root, win_root)
  job_roots = { root, win_root }
  local found, dup = scan()
  local dir = M.dir()
  for name in pairs(dup) do os.remove(dir .. '/' .. name) end
  local force = read(dir .. '/.version') ~= VERSION
  local written = 0
  for name, path in pairs(found) do
    local ok, w = pcall(update, name, path, force)
    if ok and w then written = written + 1 end
  end
  if force then
    vim.fn.mkdir(dir, 'p')
    local f = io.open(dir .. '/.version', 'wb')
    if f then f:write(VERSION) f:close() end
  end
  io.stdout:write(vim.json.encode({ headers = found, written = written }))
end

local running = false

--- Bring every shadow up to date in the background; `done(written)` afterwards.
function M.refresh(done)
  local root, win_root = roots()
  if running or not root then return end
  running = true
  local script = debug.getinfo(1, 'S').source:sub(2)
  local cmd = { vim.v.progpath, '--clean', '--headless', '-l', script, '--job', root, win_root }
  local ok = pcall(vim.system, cmd, { text = true }, vim.schedule_wrap(function(res)
    running = false
    local decoded, out = pcall(vim.json.decode, res.stdout or '')
    if res.code ~= 0 or not decoded or type(out) ~= 'table' then return end
    M.headers = type(out.headers) == 'table' and out.headers or {}
    if done then done(out.written or 0) end
  end))
  if not ok then running = false end
end

--- The shadow of the header in `buf` (X.h -> X.generated.h), when its real one changed.
local function refresh_buf(buf)
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':t:r') .. '.generated.h'
  local path = M.headers[name]
  if path then pcall(update, name, path) end
end

--- Add the flag to a .clangd this config wrote (WSL only uses it: Windows Neovim writes the whole file,
--- lang-ue.lua); true if changed.
function M.ensure_clangd_flag()
  local root = roots()
  local file = root .. '/.clangd'
  local text = read(file)
  local flag = M.clangd_flag()
  if not text or text:find(flag, 1, true) or not text:find('Add: [-D__INTELLISENSE__', 1, true) then return false end
  text = text:gsub(', "/clang:%-iquote[^"]*ClangdUHT"', ''):gsub('Add: %[%-D__INTELLISENSE__', 'Add: [-D__INTELLISENSE__, ' .. flag, 1)
  local f = io.open(file, 'wb')
  if not f then return false end
  f:write(text)
  f:close()
  return true
end

local last_focus = 0

function M.setup()
  if not roots() then return end
  local ctx = require('core.context')
  local group = vim.api.nvim_create_augroup('ue-uht-shadow', { clear = true })
  vim.defer_fn(function()
    M.refresh(function()
      -- the first time: clangd reads the new flag at its next start
      if ctx.wsl_ue and M.ensure_clangd_flag() then
        pcall(function() require('ue.compiledb').restart_clangd() end)
      end
    end)
  end, 3000)
  -- a build in the editor or Rider rewrites the generated headers while Neovim is in the background
  vim.api.nvim_create_autocmd('FocusGained', {
    group = group,
    callback = function()
      if vim.uv.now() - last_focus < 20000 then return end
      last_focus = vim.uv.now()
      M.refresh()
    end,
  })
  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    pattern = { '*.h', '*.hpp' },
    callback = function(ev) refresh_buf(ev.buf) end,
  })
end

if arg and arg[1] == '--job' then M.job(arg[2], arg[3]) end

return M
