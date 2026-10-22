-- Search Everywhere (Rider's double-Shift): one Telescope picker over project files and C/C++ symbols.
--
-- Files: `rg --files` once per picker (vim.system, off the main loop), the list kept in memory and
-- fuzzy-filtered per prompt with Telescope's sorter; the picker shows files while rg still lists.
-- Symbols: clangd workspace/symbol per prompt (the previous request cancelled), types and functions only.
-- Both go through one sorter: exact name match, then name prefix, then the fuzzy score; at equal score
-- types come before functions before files. Nothing here blocks: the finder waits with async sleeps and
-- gives up as soon as the prompt changes.
-- Without a clangd (no C/C++ project) only files show. Same rg arguments as <leader>ff.
local M = {}

local NO_CONTENT = { '-g', '!**/Content/**' } -- as lua/plugins/telescope.lua: Unreal asset folders
local MAX_RESULTS = 300
local TAG_WIDTH = 6
local NAME_WIDTH = 40

-- LSP SymbolKind name -> tag shown, and type (1) or function (2)
local KINDS = {
  Class = { 'class', 1 }, Struct = { 'struct', 1 }, Enum = { 'enum', 1 }, Interface = { 'iface', 1 },
  Function = { 'func', 2 }, Method = { 'method', 2 }, Constructor = { 'ctor', 2 },
}
local GROUP_BIAS = { 1.0, 1.1, 1.2 } -- types, functions, files: factor on the fuzzy score
local GROUP_HL = { 'Type', 'Function', 'Directory' }

local function clangd()
  for _, c in ipairs(vim.lsp.get_clients({ name = 'clangd' })) do
    if not c:is_stopped() then return c end
  end
end

local function ue_files()
  local ctx = require('core.context')
  return ctx.is_ue or ctx.wsl_ue ~= nil or ctx.ue_unix ~= nil
end

-- ---- entries ----------------------------------------------------------------------------------------

local function display(e)
  local tag = ('%-' .. TAG_WIDTH .. 's'):format(e.kind)
  local hl = { { { 0, TAG_WIDTH }, GROUP_HL[e.group] } }
  if e.group == 3 then return tag .. ' ' .. e.path, hl end
  local label = e.name
  if e.container and e.container ~= '' then label = e.container:gsub('::$', '') .. '::' .. label end
  local head = tag .. ' ' .. label
  local pad = math.max(2, TAG_WIDTH + 1 + NAME_WIDTH - #head)
  local where = vim.fn.fnamemodify(e.filename, ':.'):gsub('\\', '/') .. ':' .. e.lnum
  hl[#hl + 1] = { { #head + pad, #head + pad + #where }, 'Comment' }
  return head .. (' '):rep(pad) .. where, hl
end

local Class = { display = display }

-- clangd's positions count UTF-16 units; Neovim's columns are bytes. The line is read only when a row is
-- previewed or opened (C++ lines with Cyrillic comments before a name were off).
local symbol_mt = { __index = function(e, k)
  if k ~= 'col' then return Class[k] end
  local col = e.char + 1
  local buf = vim.fn.bufnr(e.filename)
  local line = buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_lines(buf, e.lnum - 1, e.lnum, false)[1]
  if not line then
    local n = 0
    for l in io.lines(e.filename) do
      n = n + 1
      if n == e.lnum then line = l; break end
    end
  end
  if line and e.char > 0 then
    local ok, byte = pcall(vim.str_byteindex, line, 'utf-16', e.char, false)
    if ok and byte then col = byte + 1 end
  end
  rawset(e, 'col', col)
  return col
end }

local function symbol_entries(res)
  local out = {}
  local ue = ue_files()
  for _, s in ipairs(res or {}) do
    local k = KINDS[vim.lsp.protocol.SymbolKind[s.kind] or '']
    local loc = s.location
    if k and loc and loc.uri then
      local start = loc.range and loc.range.start or { line = 0, character = 0 }
      local filename = vim.uri_to_fname(loc.uri)
      -- UHT's generated code (Z_Construct_*, StaticRegisterNatives...) is noise next to the real classes
      if not (ue and filename:find('[/\\]Intermediate[/\\]')) then
        out[#out + 1] = setmetatable({
          kind = k[1], group = k[2], name = s.name, container = s.containerName, ordinal = s.name,
          value = s.name, filename = filename, lnum = start.line + 1, char = start.character,
        }, symbol_mt)
      end
    end
  end
  return out
end

-- ---- sorter -----------------------------------------------------------------------------------------

--- Telescope's fuzzy sorter (fzf-native when built) plus the ranking: exact name, name prefix, rest.
local function make_sorter()
  require('telescope')
  local base = require('telescope.config').values.generic_sorter({})
  local lprompt = ''
  return require('telescope.sorters').Sorter:new({
    init = function() base:_init() end,
    destroy = function() base:_destroy() end,
    start = function(_, prompt) lprompt = prompt:lower(); base:_start(prompt) end,
    scoring_function = function(_, prompt, ordinal, entry)
      if prompt == '' then return 1 + (entry.index or 0) * 1e-7 end -- listing order
      local s = base:scoring_function(prompt, ordinal)
      if s < 0 then
        if entry.group == 3 then return -1 end
        s = 0.2 -- clangd matched it by its own rules: keep, ranked low
      end
      local lname = entry.lname
      if not lname then
        lname = (entry.name or entry.path:match('([^/]*)$')):gsub('%.[^.]*$', ''):lower()
        entry.lname = lname
        -- Unreal type prefix (AFoo, UFoo, FFoo...): "foo" is an exact match for it too
        local bare = entry.name and entry.name:match('^[AUFEIST]%u') and entry.name:sub(2):lower()
        entry.lbare = bare or lname
      end
      local tier = (lname == lprompt or entry.lbare == lprompt) and 0
        or ((lname:sub(1, #lprompt) == lprompt or entry.lbare:sub(1, #lprompt) == lprompt) and 1 or 2)
      -- exact and prefix name matches: types, then functions, then files, whatever their fuzzy scores
      if tier < 2 then return tier + (entry.group - 1) * 0.05 + s end
      return tier + s * GROUP_BIAS[entry.group]
    end,
    highlighter = function(_, prompt, text)
      -- the name (a symbol's file:line after the padding is not what was matched) or the path; not the tag
      local body = text:sub(TAG_WIDTH + 2)
      local pad = body:find('  ', 1, true)
      local pos = base:highlighter(prompt, pad and body:sub(1, pad - 1) or body)
      if not pos then return pos end
      for i, p in ipairs(pos) do pos[i] = p + TAG_WIDTH + 1 end
      return pos
    end,
  })
end

-- ---- picker -----------------------------------------------------------------------------------------

--- Start `rg --files`; entries are appended to `files` as output arrives.
local function list_files(cwd, files, mt, state)
  if vim.fn.executable('rg') ~= 1 then
    state.done = true
    return vim.notify('rg not found: symbols only', vim.log.levels.WARN, { title = 'Search everywhere' })
  end
  local cmd = { 'rg', '--files', '--color', 'never' }
  if ue_files() then vim.list_extend(cmd, NO_CONTENT) end
  local rest = ''
  local function add(chunk)
    for line in chunk:gmatch('[^\r\n]+') do
      local path = line:gsub('\\', '/')
      files[#files + 1] = setmetatable({ kind = 'file', group = 3, path = path, ordinal = path, value = path,
        index = #files + 1 }, mt)
    end
  end
  state.job = vim.system(cmd, {
    cwd = cwd,
    text = true,
    stdout = function(_, data)
      if not data then return end
      data = rest .. data
      local cut = data:find('[^\r\n]*$')
      rest = data:sub(cut)
      add(data:sub(1, cut - 1))
    end,
  }, function() add(rest); rest = ''; state.done = true end)
end

function M.open()
  local a = require('plenary.async')
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  local files, state = {}, { done = false }
  local file_mt = { __index = function(e, k)
    if k == 'filename' then return cwd .. '/' .. e.path end
    return Class[k]
  end }
  list_files(cwd, files, file_mt, state)

  local pending -- id of the workspace/symbol request in flight
  local shown = {} -- prompt -> signature of the symbols last shown for it
  local function signature(items)
    local names = {}
    for i = 1, math.min(#items, 100) do names[i] = items[i].name end
    return #items .. '\n' .. table.concat(names, '\n')
  end

  local finder = setmetatable({ results = {}, entry_maker = function(e) return e end }, {
    __call = function(_, prompt, process_result, process_complete)
      local sym -- { entries = ... } once clangd answered
      local sent = prompt == '' -- nothing to ask for an empty prompt
      local fed_sym = sent
      local next_file = 1
      local waited = 0
      while true do
        if process_result(nil) then return end -- the prompt changed: this run is stale
        -- symbols: ask once clangd is up, show them when they arrive
        if not sent then
          local c = clangd()
          if c and c.initialized then
            sent = true
            require('core.symbols').load_index(c) -- a bufferless clangd loads its index only when told to
            if pending then c:cancel_request(pending) end
            local ok, id = c:request('workspace/symbol', { query = prompt }, function(err, res)
              if not err and res then sym = { res = res } end
              if not sym then sym = { res = {} } end
            end)
            if ok then pending = id else sym = { res = {} } end
          elseif not c or waited > 20000 then
            sent, fed_sym = true, true -- no clangd here (or it never came up): files only
          end
        end
        if sym and not sym.entries then
          sym.entries = symbol_entries(sym.res)
          shown[prompt] = signature(sym.entries)
        end
        if sym and not fed_sym then
          fed_sym = true
          for _, e in ipairs(sym.entries) do
            if process_result(e) then return end
          end
        end
        -- files: whatever rg has listed so far
        local n = #files
        for i = next_file, n do
          if process_result(files[i]) then return end
          if i % 1000 == 0 then a.util.scheduler() end
        end
        next_file = n + 1
        if state.done and next_file > #files and fed_sym then break end
        a.util.sleep(15)
        waited = waited + 15
      end
      process_complete()
    end,
  })
  finder.close = function()
    if state.job and not state.done then pcall(state.job.kill, state.job, 15) end
    local c = clangd()
    if c and pending then c:cancel_request(pending) end
  end

  local conf = require('telescope.config').values
  local opts = { temp__scrolling_limit = MAX_RESULTS }
  local picker = require('telescope.pickers').new(opts, {
    prompt_title = 'Search everywhere',
    finder = finder,
    previewer = conf.qflist_previewer(opts),
    sorter = make_sorter(),
  })
  picker:find()

  -- clangd loads without a file open (as the symbol finders do); this is after the picker is up
  vim.schedule(function()
    if not clangd() then pcall(require('core.symbols').ensure_clangd) end
  end)

  -- clangd answers from what it has indexed so far: while it indexes, ask again for the prompt every 2 s
  -- and refresh when the answer differs
  local timer = assert(vim.uv.new_timer())
  local quiet = 0
  timer:start(2000, 2000, vim.schedule_wrap(function()
    if picker.closed or not vim.api.nvim_buf_is_valid(picker.prompt_bufnr or -1) then
      if not timer:is_closing() then timer:stop(); timer:close() end
      return
    end
    local ok, indexing = pcall(function() return require('core.clangd').indexing() end)
    quiet = (ok and indexing) and 0 or quiet + 1
    if quiet > 2 then return end
    local prompt, c = picker:_get_prompt(), clangd()
    if not c or prompt == '' or shown[prompt] == nil then return end
    c:request('workspace/symbol', { query = prompt }, vim.schedule_wrap(function(err, res)
      if err or picker.closed or picker:_get_prompt() ~= prompt then return end
      if signature(symbol_entries(res)) ~= shown[prompt] then picker:refresh() end
    end))
  end))
end

return M
