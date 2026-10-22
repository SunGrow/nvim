-- Symbol finders for <leader>f (Rider's Go to Class / Go to Symbol / Go to File Member).
--
-- Workspace search asks clangd directly (workspace/symbol, one request per keystroke, the previous one
-- cancelled). Telescope's lsp_dynamic_workspace_symbols sends to every client of the current buffer
-- (ue_ls too) and needs that buffer to be a C++ file; this works from any buffer once clangd runs.
-- clangd answers from its index: project symbols appear as the background index covers them.
local M = {}

local FUNCTIONS = { Function = true, Method = true, Constructor = true }
local TYPES = { Class = true, Struct = true, Enum = true, Interface = true }

local function clangd()
  for _, c in ipairs(vim.lsp.get_clients({ name = 'clangd' })) do
    if not c:is_stopped() then return c end
  end
end

--- Root of the C/C++ project in the working directory, as clangd would get it for a file there; nil
--- when the folder is not one (no Unreal project, no compile database).
local function project_root(cfg)
  local ctx = require('core.context')
  local ue = ctx.wsl_ue or ctx.ue_unix
  if ue then return ue.root end
  if ctx.is_ue then return ctx.ue_project_root end
  local cwd = vim.fn.getcwd()
  local cdb = require('core.compiledb')
  if not (cdb.found(cwd .. '/x') or cdb.db_dir(cwd)) then return nil end
  return vim.fs.root(cwd, cfg.root_markers or { '.git' }) or cwd
end

--- The running clangd, or one started for the project in the working directory without a file (an empty
--- Neovim in a project, like opening a solution in Rider). A file opened later joins it (same name and
--- root). Returns nil outside a C/C++ project.
function M.ensure_clangd()
  local client = clangd()
  if client then return client end
  require('lazy').load({ plugins = { 'nvim-lspconfig' } }) -- loads on the first file read otherwise
  local cfg = vim.lsp.config.clangd
  local root = cfg and project_root(cfg)
  if not root then return nil end
  local id = vim.lsp.start(vim.tbl_extend('force', vim.deepcopy(cfg), { name = 'clangd', root_dir = root }),
    { attach = false, silent = true })
  client = id and vim.lsp.get_client_by_id(id) or nil
  -- statusline "⠋ clangd starting" / "loading index" until search works (no file shows its state)
  if client then require('core.clangd').watch_index(client) end
  return client
end

--- For a clangd restart (new database, thread count): true if a clangd runs without a file, which
--- `vim.lsp.enable` (FileType of loaded buffers) would not start again.
function M.fileless()
  for _, c in ipairs(vim.lsp.get_clients({ name = 'clangd' })) do
    if not next(c.attached_buffers) then return true end
  end
  return false
end

--- After a restart: start that fileless clangd again when no file brought one back.
function M.restart_fileless(had)
  if had and not clangd() then M.ensure_clangd() end
end

--- clangd reads the compile database, and with it loads its index, only when a file asks for its flags:
--- a client with no file open answered workspace/symbol with nothing (tested: 0 results after 60 s).
--- It is told about one instead: didOpen + didClose of an empty file at the project root, no buffer
--- (tested on V2: 13 results 11 s after startup). That parse costs one preamble build, as opening any
--- file would (UE: ~300 MB, 20-50 s of one core).
local kicked = {}
function M.load_index(client)
  if not client or kicked[client.id] or next(client.attached_buffers) or not client.root_dir then return end
  kicked[client.id] = true
  local uri = vim.uri_from_fname(client.root_dir .. '/.nvim-clangd-index.cpp')
  client:notify('textDocument/didOpen', { textDocument = { uri = uri, languageId = 'cpp', version = 0, text = '' } })
  client:notify('textDocument/didClose', { textDocument = { uri = uri } })
end

--- Live picker over clangd's workspace symbols; kinds: set of LSP kind names, nil for all.
function M.workspace(kinds, title)
  local client = clangd()
  if not client then
    client = M.ensure_clangd()
    if not client then
      return vim.notify('No C/C++ project here (no compile_commands.json): open a C++ file first',
        vim.log.levels.WARN, { title = title })
    end
  end
  -- a clangd just started is not initialized yet (WSL: ~1 s through interop): the picker opens now, the
  -- index is kicked and searches are sent once it is (a vim.wait here froze the editor meanwhile)
  local function kick()
    if not kicked[client.id] and not next(client.attached_buffers) then
      vim.notify('clangd is loading the project index: results appear in a few seconds (type again)',
        vim.log.levels.INFO, { title = title })
      M.load_index(client)
    end
  end
  if client.initialized then
    kick()
  else
    local waited, ready = 0, assert(vim.uv.new_timer())
    ready:start(50, 50, vim.schedule_wrap(function()
      waited = waited + 50
      if not (client.initialized or client:is_stopped() or waited >= 15000) then return end
      if not ready:is_closing() then ready:stop(); ready:close() end
      if client.initialized then kick() end
    end))
  end
  local sleep = require('plenary.async.util').sleep
  local channel = require('plenary.async.control').channel
  local pending -- id of the request in flight
  local shown = {} -- prompt -> signature of the results last shown for it
  local function items_of(c, res)
    local items = {}
    for _, item in ipairs(vim.lsp.util.symbols_to_items(res or {}, 0, c.offset_encoding)) do
      if not kinds or kinds[item.kind] then items[#items + 1] = item end
    end
    return items
  end
  local function signature(items)
    local names = {}
    for i = 1, math.min(#items, 100) do names[i] = items[i].text end
    return #items .. '\n' .. table.concat(names, '\n')
  end
  local function search(prompt)
    -- the clangd running now: a restart (new database, thread count) replaces the client
    local c = clangd() or client
    if pending then c:cancel_request(pending) end
    if not prompt or prompt == '' then return {} end
    for _ = 1, 300 do -- up to 15 s for a clangd that is starting
      if c.initialized or c:is_stopped() then break end
      sleep(50)
    end
    local tx, rx = channel.oneshot()
    local ok, id
    ok, id = c:request('workspace/symbol', { query = prompt }, function(err, res)
      if pending == id then pending = nil end -- answered: cancelling it would log "Cannot find request"
      tx(err, res)
    end)
    if not ok then return {} end
    pending = id
    local err, res = rx()
    if err or not res then return {} end
    local items = items_of(c, res)
    shown[prompt] = signature(items)
    return items
  end
  local opts = { bufnr = 0, ignore_filename = false, symbol_width = 60, symbol_type_width = 11 }
  local conf = require('telescope.config').values
  local picker = require('telescope.pickers').new(opts, {
    prompt_title = title,
    finder = require('telescope.finders').new_dynamic({
      fn = search,
      entry_maker = require('telescope.make_entry').gen_from_lsp_symbols(opts),
    }),
    previewer = conf.qflist_previewer(opts),
    sorter = require('telescope.sorters').highlighter_only(opts),
  })
  picker:find()

  -- clangd answers from what it has indexed so far: while it indexes (and once after), ask again for
  -- the prompt every 2 s, and show the new results when they differ
  local timer = assert(vim.uv.new_timer())
  local quiet = 0 -- checks since the index stopped
  timer:start(2000, 2000, vim.schedule_wrap(function()
    if picker.closed or not vim.api.nvim_buf_is_valid(picker.prompt_bufnr or -1) then
      if not timer:is_closing() then timer:stop(); timer:close() end
      return
    end
    quiet = require('core.clangd').indexing() and 0 or quiet + 1
    if quiet > 2 then return end
    local prompt = picker:_get_prompt()
    local c = clangd()
    if not c or not c.initialized or prompt == '' or pending then return end
    c:request('workspace/symbol', { query = prompt }, vim.schedule_wrap(function(err, res)
      if err or picker.closed or picker:_get_prompt() ~= prompt then return end
      if signature(items_of(c, res)) ~= shown[prompt] then picker:refresh() end
    end))
  end))
end

function M.functions() M.workspace(FUNCTIONS, 'Find function (clangd)') end
function M.types() M.workspace(TYPES, 'Find class (clangd)') end
function M.all() M.workspace(nil, 'Find symbol (clangd)') end

--- Classes: UEP's class index in UE projects (complete once UNL has indexed; engine included),
--- clangd elsewhere or while that index is not ready.
function M.classes()
  if not require('core.context').is_ue then return M.types() end
  local ok, remote = pcall(require, 'UNL.db.remote')
  if not ok then return M.types() end
  remote.get_components(vim.schedule_wrap(function(components, err)
    if not err and type(components) == 'table' and #components > 0 then return vim.cmd('UEP classes') end
    M.types()
  end))
end

--- Members of the current file (Rider's Go to File Member). Asks clangd only: telescope's
--- lsp_document_symbols fails when ue_ls is attached to the same buffer.
function M.members()
  local buf = vim.api.nvim_get_current_buf()
  local client = vim.lsp.get_clients({ bufnr = buf, name = 'clangd' })[1]
    or vim.lsp.get_clients({ bufnr = buf, method = 'textDocument/documentSymbol' })[1]
  if not client then
    return vim.notify('No language server with symbols for this file', vim.log.levels.WARN, { title = 'Find member' })
  end
  client:request('textDocument/documentSymbol', { textDocument = vim.lsp.util.make_text_document_params(buf) },
    function(err, res)
      if err or not res or #res == 0 then
        return vim.notify('No symbols in this file (yet)', vim.log.levels.INFO, { title = 'Find member' })
      end
      local opts = { bufnr = buf, symbol_width = 60, symbol_type_width = 11 }
      local conf = require('telescope.config').values
      require('telescope.pickers').new(opts, {
        prompt_title = 'Find member: ' .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':t'),
        finder = require('telescope.finders').new_table({
          results = vim.lsp.util.symbols_to_items(res, buf, client.offset_encoding),
          entry_maker = require('telescope.make_entry').gen_from_lsp_symbols(opts),
        }),
        previewer = conf.qflist_previewer(opts),
        sorter = conf.prefilter_sorter({ tag = 'symbol_type', sorter = conf.generic_sorter(opts) }),
      }):find()
    end, buf)
end

return M
