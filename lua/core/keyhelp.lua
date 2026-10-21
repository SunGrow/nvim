-- F1: one screen of the keys that do IDE things, grouped by what you want to do (Rider's keymap where
-- it has one). Made from the real mappings: a key that is not mapped here (LSP keys outside a code
-- file, Unreal keys outside a UE project) is dimmed. While debugging, the debugger keys come first.
-- Everything else: <leader>? searches every key with its description; <Space> and wait shows the
-- leader menu; `?` in a debugger panel lists the debugger keys.
local M = {}

-- { key as shown, lhs to check (nil: built into Neovim, always there), what it does }
local SECTIONS = {
  { 'Help', {
    { 'F1', '<F1>', 'This sheet' },
    { 'Space ?', '<leader>?', 'Search all keys by what they do' },
    { 'Space', nil, 'Wait: menu of the Space keys' },
    { '?', nil, 'Debugger keys (in its panels)' },
  } },
  { 'Find', {
    { 'Space ff', '<leader>ff', 'File by name' },
    { 'Space fg', '<leader>fg', 'Text in all files' },
    { 'Space fc', '<leader>fc', 'Class' },
    { 'Space fs', '<leader>fs', 'Function' },
    { 'Space fS', '<leader>fS', 'Any symbol' },
    { 'Space fm', '<leader>fm', 'Member of this file' },
    { 'Space fo', '<leader>fo', 'Recent files' },
    { 'Space fb', '<leader>fb', 'Open files (buffers)' },
    { 'Space fd', '<leader>fd', 'Errors and warnings' },
    { 'Space fr', '<leader>fr', 'Reopen the last search' },
  } },
  { 'Navigate code', {
    { 'F12', '<F12>', 'Go to definition' },
    { 'Alt+]', '<M-]>', 'Find usages (also Shift+F12)' },
    { 'Ctrl+F12', '<C-F12>', 'Implementations / overrides' },
    { 'Shift+Alt+H', '<S-M-h>', 'Callers' },
    { 'Space cb / cd', '<leader>cb', 'Base / derived classes' },
    { 'Alt+O', '<M-o>', 'Switch header / source' },
    { 'Ctrl+O / I', nil, 'Back / forward after a jump' },
    { 'K', nil, 'Documentation' },
    { ']d / [d', nil, 'Next / previous error' },
  } },
  { 'Edit', {
    { 'Alt+Enter', '<M-CR>', 'Quick fix (also Ctrl+.)' },
    { 'F2', '<F2>', 'Rename' },
    { 'Space cf', '<leader>cf', 'Format file' },
    { 'gcc', nil, 'Comment line (gc: selection)' },
    { 'u / Ctrl+R', nil, 'Undo / redo' },
    { 'Space s', '<leader>s', 'Save' },
  } },
  { 'Build and run (Unreal)', {
    { 'F5', '<F5>', 'Build + debug' },
    { 'Ctrl+F5', '<C-F5>', 'Build + run (no debugger)' },
    { 'Shift+F5', '<S-F5>', 'Stop' },
    { 'Ctrl+Shift+B', '<C-S-b>', 'Build' },
    { 'Space bc', '<leader>bc', 'Configuration (or click ▶)' },
    { 'Space be', '<leader>be', 'Build errors' },
  }, ue = true },
  { 'Debug', 'debug' },
  { 'Git', {
    { 'Space gc', '<leader>gc', 'Changed files (Tab stages)' },
    { ']h / [h', ']h', 'Next / previous change in this file' },
    { 'Space gp', '<leader>gp', 'Preview this change' },
    { 'Space gr', '<leader>gr', 'Undo this change' },
    { 'Space gb', '<leader>gb', 'Who changed this line' },
    { 'Space gl / gf', '<leader>gl', 'Log / history of this file' },
    { 'Space gB', '<leader>gB', 'Branches' },
  } },
  { 'Files and windows', {
    { 'Shift+H / L', '<S-h>', 'Previous / next open file' },
    { 'Space e', '<leader>e', 'File explorer' },
    { 'Space w', '<leader>w', 'Windows (then v split, q close)' },
    { 'Space un', '<leader>un', 'Notification history' },
    { 'Space uh', '<leader>uh', 'Inline hints on / off' },
    { 'Space uc', '<leader>uc', 'Color theme' },
  } },
}

local function mapped(lhs)
  if not lhs then return true end
  for _, mode in ipairs({ 'n', 'x', 'i' }) do
    if not vim.tbl_isempty(vim.fn.maparg(lhs, mode, false, true)) then return true end
  end
  return false
end

local function debug_entries()
  local list = {}
  for _, k in ipairs(require('core.debug_ui').KEYS) do
    if k.key then list[#list + 1] = { k.key, k.lhs, k.desc } end
  end
  return list
end

--- Lines and highlights for one section: { lines = {...}, hl = { {row, col_start, col_end, group} } }.
local function block(title, entries, keyw)
  local lines, hl = { title }, { { 0, 0, -1, 'Title' } }
  for _, e in ipairs(entries) do
    local key = e[1] .. string.rep(' ', keyw - vim.fn.strdisplaywidth(e[1]))
    lines[#lines + 1] = '  ' .. key .. '  ' .. e[3]
    local row = #lines - 1
    if mapped(e[2]) then
      hl[#hl + 1] = { row, 2, 2 + #key, 'Special' }
    else
      hl[#hl + 1] = { row, 0, -1, 'Comment' }
    end
  end
  return { lines = lines, hl = hl }
end

local function sheet()
  local ctx = require('core.context')
  local debugging = package.loaded['dap'] and require('dap').session() ~= nil
  local sections = {}
  for _, s in ipairs(SECTIONS) do
    if not s.ue or ctx.is_ue then
      local entries = s[2] == 'debug' and debug_entries() or s[2]
      table.insert(sections, (debugging and s[2] == 'debug') and 1 or #sections + 1, { s[1], entries })
    end
  end
  local keyw = 0
  for _, s in ipairs(sections) do
    for _, e in ipairs(s[2]) do keyw = math.max(keyw, vim.fn.strdisplaywidth(e[1])) end
  end
  local blocks = {}
  for _, s in ipairs(sections) do blocks[#blocks + 1] = block(s[1], s[2], keyw) end
  return blocks
end

--- Lays blocks out in as many columns as fit, filling columns top to bottom.
local function layout(blocks, max_cols)
  local colw = 0
  for _, b in ipairs(blocks) do
    for _, l in ipairs(b.lines) do colw = math.max(colw, vim.fn.strdisplaywidth(l)) end
  end
  colw = colw + 3
  local ncols = math.max(1, math.min(3, math.floor(max_cols / colw)))
  -- pack the sections into columns of about equal height (largest first, into the shortest column;
  -- the Debug section alone is a third of the sheet), then keep each column in reading order
  ncols = math.min(ncols, #blocks)
  local order = {}
  for i = 1, #blocks do order[i] = i end
  table.sort(order, function(a, b) return #blocks[a].lines > #blocks[b].lines end)
  local cols_idx, heights = {}, {}
  for c = 1, ncols do cols_idx[c], heights[c] = {}, 0 end
  for _, i in ipairs(order) do
    local c = 1
    for k = 2, ncols do if heights[k] < heights[c] then c = k end end
    table.insert(cols_idx[c], i)
    heights[c] = heights[c] + #blocks[i].lines + 1
  end
  for c = 1, ncols do table.sort(cols_idx[c]) end
  table.sort(cols_idx, function(a, b) return (a[1] or math.huge) < (b[1] or math.huge) end)
  local columns = {}
  for c, idx in ipairs(cols_idx) do
    columns[c] = {}
    for _, i in ipairs(idx) do table.insert(columns[c], blocks[i]) end
  end
  local lines, hls = {}, {}
  for c, col in ipairs(columns) do
    local row = 0
    for _, b in ipairs(col) do
      for i, l in ipairs(b.lines) do
        local r = row + i
        lines[r] = lines[r] or ''
        local pad = (c - 1) * colw - vim.fn.strdisplaywidth(lines[r])
        if pad > 0 then lines[r] = lines[r] .. string.rep(' ', pad) end
        local off = #lines[r]
        lines[r] = lines[r] .. l
        for _, h2 in ipairs(b.hl) do
          if h2[1] == i - 1 then
            hls[#hls + 1] = { r - 1, off + h2[2], h2[3] == -1 and off + #l or off + h2[3], h2[4] }
          end
        end
      end
      row = row + #b.lines + 1
      lines[row] = lines[row] or ''
    end
  end
  for i = 1, #lines do lines[i] = lines[i] or '' end
  return lines, hls, ncols * colw
end

--- A centered, scrollable float; q / Esc / F1 close it.
function M.float(title, lines, hls, width)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  if not width then
    width = 0
    for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l)) end
  end
  width = math.min(width + 2, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', style = 'minimal', border = 'rounded',
    title = ' ' .. title .. ' ', title_pos = 'center',
    footer = ' q / Esc close · Space ? search all keys ', footer_pos = 'center',
    width = width, height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1, col = math.floor((vim.o.columns - width) / 2),
  })
  local ns = vim.api.nvim_create_namespace('core-keyhelp')
  for _, h in ipairs(hls or {}) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  for _, key in ipairs({ 'q', '<Esc>', '<F1>' }) do
    vim.keymap.set('n', key, function() pcall(vim.api.nvim_win_close, win, true) end, { buffer = buf, nowait = true })
  end
  return win
end

--- F1: the key sheet for the current buffer.
function M.show()
  -- mappings are checked in the buffer F1 was pressed in (LSP keys are buffer-local)
  local blocks = sheet()
  local lines, hls, width = layout(blocks, vim.o.columns - 6)
  M.float('Keys  (dimmed: not available here)', lines, hls, width)
end

return M
