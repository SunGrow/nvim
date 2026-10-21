-- Rider-style code navigation on clangd: Find Usages, call hierarchy, base/derived classes,
-- implementations, and highlighting the symbol under the cursor.
--
-- Requests go to clangd only (clangd_engine in engine files). vim.lsp.buf.* sends them to every
-- client of the buffer, ue_ls included, and fills the quickfix list; these open a Telescope picker
-- with a preview instead, and jump directly when there is a single result.
local M = {}

local function client_for(buf, method)
  for _, name in ipairs({ 'clangd', 'clangd_engine' }) do
    local c = vim.lsp.get_clients({ bufnr = buf, name = name })[1]
    if c then return c end
  end
  return vim.lsp.get_clients({ bufnr = buf, method = method })[1]
end

local function warn(msg, title) vim.notify(msg, vim.log.levels.WARN, { title = title }) end

--- Shows LSP locations ({uri, range, text?}) in a picker; jumps when there is only one.
local function show(locations, client, title)
  if #locations == 0 then return vim.notify('No results', vim.log.levels.INFO, { title = title }) end
  if #locations == 1 then
    return vim.lsp.util.show_document(locations[1], client.offset_encoding, { focus = true })
  end
  vim.cmd("normal! m'") -- so <C-o> comes back here
  local items = vim.lsp.util.locations_to_items(locations, client.offset_encoding)
  for _, item in ipairs(items) do
    local loc = item.user_data
    if loc and loc.text then item.text = loc.text end
  end
  local opts = {}
  local conf = require('telescope.config').values
  require('telescope.pickers').new(opts, {
    prompt_title = title .. ' (' .. #items .. ')',
    finder = require('telescope.finders').new_table({
      results = items,
      entry_maker = require('telescope.make_entry').gen_from_quickfix(opts),
    }),
    previewer = conf.qflist_previewer(opts),
    sorter = conf.generic_sorter(opts),
  }):find()
end

--- textDocument/<method> at the cursor; the result is a Location or a list of Location/LocationLink.
local function locations(method, title, extra)
  local buf = vim.api.nvim_get_current_buf()
  local client = client_for(buf, method)
  if not client then return warn('No language server for this file', title) end
  local params = vim.tbl_extend('force', vim.lsp.util.make_position_params(0, client.offset_encoding), extra or {})
  client:request(method, params, function(err, res)
    if err then return warn(err.message, title) end
    res = res or {}
    if res.uri or res.targetUri then res = { res } end
    local locs = {}
    for _, l in ipairs(res) do
      locs[#locs + 1] = l.targetUri and { uri = l.targetUri, range = l.targetSelectionRange or l.targetRange } or l
    end
    show(locs, client, title)
  end, buf)
end

--- Rider's Find Usages (references, without the declaration).
function M.usages()
  locations('textDocument/references', 'Usages', { context = { includeDeclaration = false } })
end

--- Go to implementation: overrides of a virtual method, definitions of a declaration.
function M.implementations() locations('textDocument/implementation', 'Implementations') end

--- Call hierarchy: 'incoming' (callers, at each call site) or 'outgoing' (callees).
function M.calls(direction)
  local title = direction == 'incoming' and 'Callers' or 'Callees'
  local buf = vim.api.nvim_get_current_buf()
  local client = client_for(buf, 'textDocument/prepareCallHierarchy')
  if not client then return warn('No language server for this file', title) end
  client:request('textDocument/prepareCallHierarchy', vim.lsp.util.make_position_params(0, client.offset_encoding),
    function(err, items)
      if err then return warn(err.message, title) end
      if not items or #items == 0 then return warn('No function at the cursor', title) end
      client:request('callHierarchy/' .. direction .. 'Calls', { item = items[1] }, function(err2, calls)
        if err2 then return warn(err2.message, title) end
        local locs = {}
        for _, call in ipairs(calls or {}) do
          if direction == 'incoming' then
            -- one entry per call site, in the caller's file
            for _, r in ipairs(call.fromRanges or {}) do
              locs[#locs + 1] = { uri = call.from.uri, range = r, text = call.from.name }
            end
          else
            locs[#locs + 1] = { uri = call.to.uri, range = call.to.selectionRange, text = call.to.name }
          end
        end
        show(locs, client, title .. ' of ' .. items[1].name)
      end, buf)
    end, buf)
end

--- Type hierarchy: 'supertypes' (base classes) or 'subtypes' (derived classes; from clangd's index,
--- so complete once the background index covers the project).
function M.types(direction)
  local title = direction == 'supertypes' and 'Base classes' or 'Derived classes'
  local buf = vim.api.nvim_get_current_buf()
  local client = client_for(buf, 'textDocument/prepareTypeHierarchy')
  if not client then return warn('No language server for this file', title) end
  client:request('textDocument/prepareTypeHierarchy', vim.lsp.util.make_position_params(0, client.offset_encoding),
    function(err, items)
      if err then return warn(err.message, title) end
      if not items or #items == 0 then return warn('No class at the cursor', title) end
      client:request('typeHierarchy/' .. direction, { item = items[1] }, function(err2, types)
        if err2 then return warn(err2.message, title) end
        local locs = {}
        for _, t in ipairs(types or {}) do
          locs[#locs + 1] = { uri = t.uri, range = t.selectionRange, text = t.name }
        end
        show(locs, client, title .. ' of ' .. items[1].name)
      end, buf)
    end, buf)
end

--- Code actions (Rider's Alt+Enter): clangd fixes such as missing #include, plus ue_ls actions.
function M.actions()
  if vim.fn.mode() == 'i' then vim.cmd.stopinsert() end
  vim.lsp.buf.code_action()
end

--- Highlights the symbol under the cursor and its other uses in the file (Rider does this while
--- the caret rests), with clangd's documentHighlight. Read and write uses get different colors.
function M.attach_highlight(client, buf)
  if not client:supports_method('textDocument/documentHighlight') then return end
  local group = vim.api.nvim_create_augroup('code-highlight-' .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, {
    group = group,
    buffer = buf,
    callback = function()
      local c = client_for(buf, 'textDocument/documentHighlight')
      if not c or c:is_stopped() then return end
      local params = vim.lsp.util.make_position_params(0, c.offset_encoding)
      local pos = vim.api.nvim_win_get_cursor(0)
      c:request('textDocument/documentHighlight', params, function(err, res)
        if err or not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_get_current_buf() ~= buf then return end
        if not vim.deep_equal(vim.api.nvim_win_get_cursor(0), pos) then return end -- moved on meanwhile
        vim.lsp.util.buf_clear_references(buf)
        if res then vim.lsp.util.buf_highlight_references(buf, res, c.offset_encoding) end
      end, buf)
    end,
  })
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'BufLeave' }, {
    group = group,
    buffer = buf,
    callback = function() vim.lsp.util.buf_clear_references(buf) end,
  })
end

M.state = { hints = true }

--- Inline hints (parameter names, deduced types), shown by default like Rider's.
function M.attach_hints(client, buf)
  if M.state.hints and client:supports_method('textDocument/inlayHint') then
    vim.lsp.inlay_hint.enable(true, { bufnr = buf })
  end
end

function M.toggle_hints()
  M.state.hints = not M.state.hints
  vim.lsp.inlay_hint.enable(M.state.hints)
  vim.notify('Inline hints ' .. (M.state.hints and 'on' or 'off'), vim.log.levels.INFO, { title = 'Code' })
end

return M
