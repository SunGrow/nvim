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
-- included something for it (a third of the files sampled) then has errors. When an unmodified buffer
-- gets them, the classes they name (UGameInstance, USkeletalMesh...) are looked up in the index, and
-- their headers are force-included as well if the PCH includes them (its .dep.json from the build):
-- 4-14 s instead of 22-35 s for the files sampled. When that does not help (a name the index or the
-- PCH does not have, or errors after three rounds), the file gets the full PCH. Both are remembered
-- in Intermediate/ClangdFullPCH.txt (a path, then the added headers; a path alone: full PCH). If the
-- same errors remain with the full PCH, they were real ones and the file is forgotten again.

local M = {}

local ctx = require('core.context')

local LIST = '/Intermediate/ClangdFullPCH.txt'

-- clangd loads the project's index (enqueues every database file) only when it looks up a file the
-- light commands do not cover. So each server first opens this empty file, which .clangd gives no
-- forced includes (it parses at once), and closes it again.
M.START = 'Intermediate/ClangdStart.cpp'
M.START_MATCH = 'PathMatch: ' .. M.START:gsub('%.', '\\.') -- also how .clangd writers find the fragment
M.CLANGD_FRAGMENT = table.concat({
  '---',
  'If:',
  '  ' .. M.START_MATCH,
  'CompileFlags:',
  '  Remove: [/FI]',
  '',
}, '\n')

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

--- The full command (argument list) of an entry, the shared PCH it force-includes, and the light
--- command with `extra` headers force-included too; nil when it has no shared PCH.
local function commands(e, extra)
  local full = split(e.command)
  local light, found = {}, nil
  for _, a in ipairs(full) do
    local pch = not found and a:match('^/FI(.*SharedPCH%.[^/\\]*%.h)$')
    if pch then
      found = pch
      local defs = pch:gsub('SharedPCH%.([^/\\]*%.h)$', 'SharedDefinitions.%1')
      if vim.uv.fs_stat(here(defs)) then light[#light + 1] = '/FI' .. defs end
      light[#light + 1] = '/FICoreMinimal.h'
      for _, h in ipairs(extra or {}) do light[#light + 1] = '/FI' .. h end
    else
      light[#light + 1] = a
    end
  end
  if not found then return nil end
  return full, found, light
end

local pch_sets = {} -- PCH path -> { mtime, set of lower-case headers it includes }

--- Headers the PCH includes (lower case, /), from the .dep.json its build wrote; nil without one.
local function pch_headers(pch)
  local path = here(pch .. '.dep.json')
  local st = vim.uv.fs_stat(path)
  if not st then return nil end
  local c = pch_sets[pch]
  if c and c.mtime == st.mtime.sec then return c.set end
  local ok, dep = pcall(vim.json.decode, read(path) or '')
  local includes = ok and type(dep) == 'table' and type(dep.Data) == 'table' and dep.Data.Includes
  if type(includes) ~= 'table' then return nil end
  local set = {}
  for _, h in ipairs(includes) do set[key(h)] = true end
  pch_sets[pch] = { mtime = st.mtime.sec, set = set }
  return set
end

-- Remembered files: lower-case Windows path -> true (full PCH) or the headers to add. Read again for
-- each use: Windows and WSL Neovim share the file.
local function list_path()
  local root = roots()
  return root .. LIST
end
local function load_list()
  local list = {}
  for line in (read(list_path()) or ''):gmatch('[^\r\n]+') do
    local path, headers = line:match('^([^\t]+)\t(.+)$')
    if path then
      list[path] = vim.split(headers, '|', { plain = true })
    else
      list[line] = true
    end
  end
  return list
end
--- Remember `path` with true (full PCH), a list of headers, or nil (forget it).
local function remember(path, value)
  local list = load_list()
  list[key(path)] = value
  local lines = {}
  for p, v in pairs(list) do lines[#lines + 1] = v == true and p or (p .. '\t' .. table.concat(v, '|')) end
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

--- Names the errors say are missing: incomplete or unknown types and undeclared identifiers, and the
--- token an error in an included file points at ("expected class name" after `: public`).
local function missing_names(diagnostics)
  local names = {}
  local function add(text)
    for q in text:gmatch("'([^']+)'") do
      local name = q:gsub('^const ', ''):gsub('^class ', ''):gsub('^struct ', ''):gsub('[%s%*&]+$', '')
      if name:match('^[%a_][%w_]*$') then names[name] = true end
    end
  end
  for _, d in ipairs(diagnostics or {}) do
    if d.severity == 1 then
      local msg = (d.message or ''):gsub('; did you mean.*$', '')
      if msg:find('incomplete', 1, true) or msg:find('undeclared', 1, true) or msg:find('unknown type', 1, true) then
        add(msg)
      end
      for _, r in ipairs(d.relatedInformation or {}) do
        local rmsg = r.message or ''
        if rmsg:find('^Forward declaration') or rmsg:find('incomplete', 1, true) then
          add(rmsg)
        elseif rmsg == 'Error occurred here' and d.code == 'expected_class_name' then
          local file = clangd_path(r.location.uri)
          local at = r.location.range.start
          local lines = file and vim.fn.readfile(here(file), '', at.line + 1) or {}
          local name = lines[at.line + 1] and lines[at.line + 1]:sub(at.character + 1):match('^[%a_][%w_]*')
          if name then names[name] = true end
        end
      end
    end
  end
  return vim.tbl_keys(names)
end

local TYPE_KINDS = { [5] = true, [10] = true, [11] = true, [23] = true } -- class, enum, interface, struct

--- The headers that define `names` (index lookup) and that the PCH includes: `done(paths)`.
local function headers_for(client, names, allowed, done)
  local found, left = {}, #names
  if left == 0 then return done({}) end
  for _, name in ipairs(names) do
    client:request('workspace/symbol', { query = name }, function(err, res)
      for _, s in ipairs((not err and res) or {}) do
        local path = s.name == name and TYPE_KINDS[s.kind] and s.location and s.location.uri
          and clangd_path(s.location.uri)
        if path and allowed[key(path)] then
          found[path] = true
          break
        end
      end
      left = left - 1
      if left == 0 then done(vim.tbl_keys(found)) end
    end)
  end
end

local function send(client, path, e, argv)
  client:notify('workspace/didChangeConfiguration', {
    settings = { compilationDatabaseChanges = { [path] = { workingDirectory = e.directory, compilationCommand = argv } } },
  })
end

local function say(msg) vim.notify(msg, vim.log.levels.INFO, { title = 'clangd' }) end

--- Called for each clangd client of the project (lsp.lua on_init): light commands go out before each
--- didOpen.
function M.attach(client)
  local root, win_root = roots()
  if not win_root then return end
  -- path -> { mode = 'light' | 'full', entry, full, pch, extra = added headers, rounds,
  --           errors = the light parse's (to compare with the full PCH's), busy = looking up names }
  local mine = {}
  M.files = mine
  local notify = client.notify
  local start_uri = vim.uri_from_fname(root .. '/' .. M.START)
  local start_path, started = clangd_path(start_uri), false
  notify(client, 'textDocument/didOpen', { textDocument = { uri = start_uri, languageId = 'cpp', version = 0, text = '' } })
  client.notify = function(self, method, params)
    if method == 'textDocument/didOpen' then
      pcall(function()
        local path = clangd_path(params.textDocument.uri)
        if not path or key(path):sub(1, #win_root + 1) ~= key(win_root) .. '/' then return end
        if mine[path] then return end
        local saved = load_list()[key(path)]
        if saved == true then return end
        local e = entry_for(path)
        if not e then return end
        local extra = type(saved) == 'table' and saved or {}
        local full, pch, light = commands(e, extra)
        if not light then return end
        mine[path] = { mode = 'light', entry = e, full = full, pch = pch, extra = extra, rounds = #extra > 0 and 1 or 0 }
        send(self, path, e, light)
      end)
    end
    return notify(self, method, params)
  end

  local method = 'textDocument/publishDiagnostics'
  local show = client.handlers[method]
  client.handlers[method] = function(err, result, hctx, config)
    if result and clangd_path(result.uri) == start_path then
      -- parsed: the index is loading; no buffer for it
      if not started then
        started = true
        notify(client, 'textDocument/didClose', { textDocument = { uri = start_uri } })
      end
      return
    end
    local ret = (show or vim.lsp.handlers[method])(err, result, hctx, config)
    pcall(function()
      local path = clangd_path(result.uri)
      local f = path and mine[path]
      local buf = f and vim.uri_to_bufnr(result.uri)
      if not f or f.busy or vim.bo[buf].modified then return end
      -- while a new preamble is being built, clangd publishes a parse made with the previous one
      if (require('core.clangd').file_state(result.uri) or ''):find('parsing includes', 1, true) then return end
      local set, n = errors(result.diagnostics)
      local name = vim.fs.basename(key(path))
      if f.mode == 'light' then
        if n == 0 then return end
        local function full_pch()
          f.mode, f.errors = 'full', set
          remember(path, true)
          send(client, path, f.entry, f.full)
          say(("%s: %d errors without the module's PCH; parsing again with it (remembered)"):format(name, n))
        end
        local allowed = f.rounds < 3 and pch_headers(f.pch)
        if not allowed then return full_pch() end
        f.busy = true
        headers_for(client, missing_names(result.diagnostics), allowed, function(headers)
          f.busy = false
          pcall(function()
            local new = {}
            for _, h in ipairs(headers) do
              if not vim.tbl_contains(f.extra, h) then new[#new + 1] = h end
            end
            if #new == 0 then return full_pch() end
            vim.list_extend(f.extra, new)
            f.rounds = f.rounds + 1
            remember(path, f.extra)
            local _, _, light = commands(f.entry, f.extra)
            send(client, path, f.entry, light)
            local names = vim.tbl_map(function(h) return vim.fs.basename(key(h)) end, new)
            say(("%s: %d errors without the module's PCH; adding %s from it (remembered)")
              :format(name, n, table.concat(names, ', ')))
          end)
        end)
      elseif f.errors then
        -- the same errors with the full PCH mean real ones, not a missing include
        local same = n > 0
        for k in pairs(f.errors) do
          if not set[k] then same = false break end
        end
        f.errors = nil
        if same then remember(path, nil) end
      end
    end)
    return ret
  end
end

return M
