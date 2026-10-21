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

--- Live picker over clangd's workspace symbols; kinds: set of LSP kind names, nil for all.
function M.workspace(kinds, title)
  local client = clangd()
  if not client then
    return vim.notify('clangd is not running yet: open a C++ file first', vim.log.levels.WARN, { title = title })
  end
  local channel = require('plenary.async.control').channel
  local pending -- id of the request in flight
  local function search(prompt)
    if pending then client:cancel_request(pending) end
    if not prompt or prompt == '' then return {} end
    local tx, rx = channel.oneshot()
    local ok, id = client:request('workspace/symbol', { query = prompt }, function(err, res) tx(err, res) end)
    if not ok then return {} end
    pending = id
    local err, res = rx()
    if pending == id then pending = nil end
    if err or not res then return {} end
    local items = {}
    for _, item in ipairs(vim.lsp.util.symbols_to_items(res, 0, client.offset_encoding)) do
      if not kinds or kinds[item.kind] then items[#items + 1] = item end
    end
    return items
  end
  local opts = { bufnr = 0, ignore_filename = false, symbol_width = 60, symbol_type_width = 11 }
  local conf = require('telescope.config').values
  require('telescope.pickers').new(opts, {
    prompt_title = title,
    finder = require('telescope.finders').new_dynamic({
      fn = search,
      entry_maker = require('telescope.make_entry').gen_from_lsp_symbols(opts),
    }),
    previewer = conf.qflist_previewer(opts),
    sorter = require('telescope.sorters').highlighter_only(opts),
  }):find()
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
