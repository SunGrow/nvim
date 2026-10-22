-- A light preamble for the files you open in an Unreal project (Windows, and WSL in a Windows project).
--
-- Every compile database entry force-includes the module's shared PCH (ue/compiledb.lua), as the real
-- build does: SharedPCH.UnrealEd...h pulls in most of the engine. clangd cannot share or reuse UBT's
-- precompiled header, so it parses all of it into each opened file's own preamble: about 25 s and
-- 260 MB per file in CyberVolleyball6vs6, where its own includes took 4 s and 35 MB.
--
-- So before a project file is opened, clangd gets that file's command with the shared PCH replaced by
-- its definitions header and CoreMinimal.h (clangd's compilationDatabaseChanges; the database and the
-- background index of other files keep the full PCH). Code that compiles only because the PCH
-- included something for it (a third of the files sampled) then has errors: when an unmodified
-- buffer gets them, the file is parsed again with the full PCH and remembered in
-- Intermediate/ClangdFullPCH.txt. If the same errors remain with the full PCH, they were real ones
-- and the file is forgotten again.

local M = {}

local ctx = require('core.context')

local LIST = '/Intermediate/ClangdFullPCH.txt'

--- Project root here and as clangd.exe sees it (Windows path).
local function roots()
  if ctx.is_ue then return ctx.ue_project_root, ctx.ue_project_root end
  if ctx.wsl_ue then return ctx.wsl_ue.root, ctx.wsl_ue.win_root end
end

local function read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end

--- A Windows path as this Neovim reads it.
local function here(win)
  win = win:gsub('\\', '/')
  if not ctx.wsl_ue then return win end
  local root, win_root = roots()
  if win:lower():sub(1, #win_root + 1) == win_root:lower() .. '/' then return root .. win:sub(#win_root + 1) end
  local drive, rest = win:match('^(%a):(.*)$')
  return drive and ('/mnt/' .. drive:lower() .. rest) or win
end

--- The path clangd uses for a buffer's URI (after --path-mappings in WSL): Windows, native separators.
local function clangd_path(uri)
  local path = vim.uri_to_fname(uri):gsub('\\', '/')
  if ctx.wsl_ue then
    local root, win_root = roots()
    if path:sub(1, #root + 1) == root .. '/' then
      path = win_root .. path:sub(#root + 1)
    else
      local drive, rest = path:match('^/mnt/(%a)(/.*)$')
      if not drive then return nil end
      path = drive:upper() .. ':' .. rest
    end
  end
  path = path:gsub('^(%a):', function(d) return d:upper() .. ':' end)
  return (path:gsub('/', '\\'))
end

local function key(win) return win:gsub('\\', '/'):lower() end

--- Split a Windows command line ("a b" c/"d" -> a b, cd).
local function split(cmd)
  local out, cur, quoted, any = {}, {}, false, false
  for ch in cmd:gmatch('.') do
    if ch == '"' then
      quoted, any = not quoted, true
    elseif ch:match('%s') and not quoted then
      if any then out[#out + 1] = table.concat(cur) end
      cur, any = {}, false
    else
      cur[#cur + 1] = ch
      any = true
    end
  end
  if any then out[#out + 1] = table.concat(cur) end
  return out
end

local db = { mtime = nil, by_file = {}, by_name = {} }

--- Database entries by lower-case file path and by lower-case file name without extension.
local function load_db()
  local _, win_root = roots()
  local path = here(win_root .. '/compile_commands.json')
  local st = vim.uv.fs_stat(path)
  if not st then return nil end
  if db.mtime == st.mtime.sec then return db end
  local ok, entries = pcall(vim.json.decode, read(path) or '')
  if not ok or type(entries) ~= 'table' then return nil end
  db = { mtime = st.mtime.sec, by_file = {}, by_name = {} }
  for _, e in ipairs(entries) do
    if type(e.file) == 'string' and e.command then
      local k = key(e.file)
      db.by_file[k] = e
      local name = vim.fs.basename(k):gsub('%.[^.]*$', '')
      db.by_name[name] = db.by_name[name] or {}
      table.insert(db.by_name[name], e)
    end
  end
  return db
end

--- The entry for a file; for a header, the entry of the .cpp of the same name nearest to it.
local function entry_for(win)
  local d = load_db()
  if not d then return nil end
  local k = key(win)
  if d.by_file[k] then return d.by_file[k] end
  if not k:match('%.h$') and not k:match('%.hpp$') then return nil end
  local best, common = nil, -1
  for _, e in ipairs(d.by_name[vim.fs.basename(k):gsub('%.[^.]*$', '')] or {}) do
    local ek, n = key(e.file), 0
    while n < #k and k:byte(n + 1) == ek:byte(n + 1) do n = n + 1 end
    if n > common then best, common = e, n end
  end
  return best
end

--- The full and the light command (argument lists) of an entry; nil when it has no shared PCH.
local function commands(e)
  local full = split(e.command)
  local light, found = {}, false
  for _, a in ipairs(full) do
    local pch = not found and a:match('^/FI(.*SharedPCH%.[^/\\]*%.h)$')
    if pch then
      found = true
      local defs = pch:gsub('SharedPCH%.([^/\\]*%.h)$', 'SharedDefinitions.%1')
      if vim.uv.fs_stat(here(defs)) then light[#light + 1] = '/FI' .. defs end
      light[#light + 1] = '/FICoreMinimal.h'
    else
      light[#light + 1] = a
    end
  end
  if not found then return nil end
  return full, light
end

-- Files that need the full PCH: lower-case Windows path -> true
local list
local function list_path()
  local root = roots()
  return root .. LIST
end
local function load_list()
  if list then return list end
  list = {}
  for line in (read(list_path()) or ''):gmatch('[^\r\n]+') do list[line] = true end
  return list
end
local function save_list()
  local lines = vim.tbl_keys(list)
  table.sort(lines)
  local f = io.open(list_path(), 'wb')
  if not f then return end
  f:write(table.concat(lines, '\n') .. (#lines > 0 and '\n' or ''))
  f:close()
end

--- Errors of a publishDiagnostics: "line:code" -> true, and their number.
local function errors(diagnostics)
  local set, n = {}, 0
  for _, d in ipairs(diagnostics or {}) do
    if d.severity == 1 then
      set[d.range.start.line .. ':' .. tostring(d.code)] = true
      n = n + 1
    end
  end
  return set, n
end

local function send(client, path, e, argv)
  client:notify('workspace/didChangeConfiguration', {
    settings = { compilationDatabaseChanges = { [path] = { workingDirectory = e.directory, compilationCommand = argv } } },
  })
end

--- Called for each clangd client of the project (lsp.lua on_init): light commands go out before each
--- didOpen.
function M.attach(client)
  local _, win_root = roots()
  if not win_root then return end
  local mine = {} -- path -> { mode = 'light' | 'full', entry, full, errors = set of the light parse }
  M.files = mine
  local notify = client.notify
  client.notify = function(self, method, params)
    if method == 'textDocument/didOpen' then
      pcall(function()
        local path = clangd_path(params.textDocument.uri)
        if not path or key(path):sub(1, #win_root + 1) ~= key(win_root) .. '/' then return end
        if mine[path] or load_list()[key(path)] then return end
        local e = entry_for(path)
        if not e then return end
        local full, light = commands(e)
        if not light then return end
        mine[path] = { mode = 'light', entry = e, full = full }
        send(self, path, e, light)
      end)
    end
    return notify(self, method, params)
  end

  local method = 'textDocument/publishDiagnostics'
  local show = client.handlers[method]
  client.handlers[method] = function(err, result, hctx, config)
    local ret = (show or vim.lsp.handlers[method])(err, result, hctx, config)
    pcall(function()
      local path = clangd_path(result.uri)
      local f = path and mine[path]
      local buf = f and vim.uri_to_bufnr(result.uri)
      if not f or vim.bo[buf].modified then return end
      local set, n = errors(result.diagnostics)
      if f.mode == 'light' then
        if n == 0 then return end
        f.mode, f.errors = 'full', set
        load_list()[key(path)] = true
        save_list()
        send(client, path, f.entry, f.full)
        vim.notify(("%s: %d errors without the module's PCH; parsing again with it (remembered)")
          :format(vim.fs.basename(key(path)), n), vim.log.levels.INFO, { title = 'clangd' })
      elseif f.errors then
        -- the first parse with the full PCH: the same errors mean real ones, not a missing include
        local same = n > 0
        for k in pairs(f.errors) do
          if not set[k] then same = false break end
        end
        f.errors = nil
        if same then
          load_list()[key(path)] = nil
          save_list()
        end
      end
    end)
    return ret
  end
end

return M
