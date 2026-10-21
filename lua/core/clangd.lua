-- clangd extras.
--
-- Parse status: clangd's textDocument/clangd.fileStatus notifications ("building preamble",
-- "parsing main file", ...) per file, shown in the statusline for the current buffer. Until a file's
-- preamble is built clangd has no AST for it: no semantic colors, hover or go-to-definition from it.
--
-- Counterpart prewarming (UE projects): once a file is parsed, its header/source counterpart
-- (textDocument/switchSourceHeader) is opened in clangd without a buffer, so `gd` from a declaration
-- to its body or <M-o> lands on a parsed file. A UE file's preamble holds the engine headers of the
-- module's shared PCH and takes 20-50 s to build. Neovim's own didOpen for the file later replaces
-- the text (same text: the preamble is reused); otherwise it is closed with the buffer it came from.
--
-- M.prewarm() does the same for other files the user is about to open: the project files of the
-- debugger's call stack when it stops (lua/core/debug_ui.lua).
local M = {}

local MAX_WARM = 3

local status = {}  -- uri -> clangd file state
local pending = {} -- uri -> client id: prewarm the counterpart once this file is idle
local warm = {}    -- uri -> { client = id, origin = bufnr, seq = n } open in clangd without a buffer
local seq = 0

local SPIN = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }

local function close_warm(uri)
  local w = warm[uri]
  warm[uri] = nil
  local client = w and vim.lsp.get_client_by_id(w.client)
  if client and not client:is_stopped() then
    client:notify('textDocument/didClose', { textDocument = { uri = uri } })
  end
end

--- File text as Neovim sends it: LF line endings, no BOM, trailing newline.
local function file_text(fname)
  local f = io.open(fname, 'rb')
  if not f then return nil end
  local text = f:read('*a')
  f:close()
  text = text:gsub('^\239\187\191', ''):gsub('\r\n', '\n')
  if text ~= '' and text:sub(-1) ~= '\n' then text = text .. '\n' end
  if not pcall(vim.json.encode, text) then return nil end -- not UTF-8
  return text
end

--- Opens a project file in clangd without a buffer (keeps the MAX_WARM most recent).
--- origin: the buffer whose deletion closes it, or a tag such as 'dap'.
local function warm_open(client, fname, origin)
  local uri = vim.uri_from_fname(fname)
  if warm[uri] then return end
  local b = vim.fn.bufnr(fname)
  if b ~= -1 and vim.api.nvim_buf_is_loaded(b) then return end -- open in Neovim already
  local root = require('core.context').ue_project_root
  if not root or vim.fs.normalize(fname):lower():sub(1, #root + 1) ~= root:lower() .. '/' then return end
  local text = file_text(fname)
  if not text then return end
  -- forget documents of clients that are gone (clangd restarted)
  for u, w in pairs(warm) do
    if not vim.lsp.get_client_by_id(w.client) then warm[u] = nil end
  end
  local count, oldest = 0, nil
  for u, w in pairs(warm) do
    count = count + 1
    if not oldest or w.seq < warm[oldest].seq then oldest = u end
  end
  if count >= MAX_WARM and oldest then close_warm(oldest) end
  seq = seq + 1
  warm[uri] = { client = client.id, origin = origin, seq = seq }
  client:notify('textDocument/didOpen', {
    textDocument = { uri = uri, languageId = 'cpp', version = 0, text = text },
  })
end

local function prewarm_counterpart(client, uri)
  local bufnr = vim.uri_to_bufnr(uri)
  client:request('textDocument/switchSourceHeader', { uri = uri }, function(err, other)
    if err or type(other) ~= 'string' or other == '' then return end
    warm_open(client, vim.uri_to_fname(other), bufnr)
  end, bufnr)
end

--- Starts clangd's parse of up to MAX_WARM project files the user is likely to open next.
--- Earlier files win; files open in Neovim are skipped.
function M.prewarm(fnames, origin)
  local client = vim.lsp.get_clients({ name = 'clangd' })[1]
  if not client or not require('core.context').is_ue then return end
  local n = 0
  for _, fname in ipairs(fnames) do
    if n >= MAX_WARM then break end
    local before = warm[vim.uri_from_fname(fname)]
    warm_open(client, fname, origin)
    if warm[vim.uri_from_fname(fname)] and not before then n = n + 1 end
  end
end

--- Closes the files prewarmed with the given origin tag.
function M.release(origin)
  for u, w in pairs(warm) do
    if w.origin == origin then close_warm(u) end
  end
end

--- Handler for clangd's textDocument/clangd.fileStatus notification.
function M.on_file_status(_, result, ctx)
  if type(result) ~= 'table' or not result.uri then return end
  status[result.uri] = result.state
  if result.state == 'idle' and pending[result.uri] == ctx.client_id then
    pending[result.uri] = nil
    local client = vim.lsp.get_client_by_id(ctx.client_id)
    if client then prewarm_counterpart(client, result.uri) end
  end
  vim.cmd.redrawstatus()
end

--- LspAttach of a clangd client.
function M.on_attach(client, bufnr)
  local uri = vim.uri_from_bufnr(bufnr)
  if warm[uri] then
    warm[uri] = nil -- Neovim owns the document now (its didOpen replaced ours)
  end
  if require('core.context').is_ue and client.name == 'clangd' then
    pending[uri] = client.id
  end
  if not M._autocmds then
    M._autocmds = true
    local group = vim.api.nvim_create_augroup('core-clangd', { clear = true })
    vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
      group = group,
      callback = function(ev)
        pending[vim.uri_from_bufnr(ev.buf)] = nil
        for u, w in pairs(warm) do
          if w.origin == ev.buf then close_warm(u) end
        end
      end,
    })
  end
end

--- Statusline: the current file's clangd state while it is not idle, e.g. "⠋ building preamble".
function M.text()
  local st = status[vim.uri_from_bufnr(0)]
  if not st or st == 'idle' then return '' end
  -- clangd reports e.g. "parsing includes, running Update": the first phase is enough
  return SPIN[(math.floor(vim.uv.now() / 120) % #SPIN) + 1] .. ' clangd ' .. (st:match('^[^,]+') or st)
end

--- For tests and :lua inspection.
function M.state()
  return { status = status, pending = pending, warm = warm }
end

return M
