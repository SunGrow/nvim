-- Debugger UI (nvim-dap-ui) set up to read like Rider's debug tool window:
--   * plain Unicode icons and signs: the terminal font (Cascadia Mono) has no Nerd Font glyphs, and
--     dap-ui's defaults are Nerd Font private-use characters that show as "?"
--   * every panel has a title bar with its keys (frames, breakpoints, variables, watches)
--   * a click opens a frame or breakpoint (dap-ui's default is <CR> / double-click only)
--   * breakpoints are their own panel with a count and the exception settings
--   * exception settings ("Suspend on ensure", C++ throw, access violation) are toggled with
--     <leader>dx / <leader>dE and kept across sessions (stdpath('state')/dap-exceptions.json)
local M = {}

-- dbgeng-dap's exceptionBreakpointFilters (tools/dbgeng-dap/dbgeng_dap/adapter.py EXC_FILTERS)
M.FILTERS = {
  { id = 'ensure', label = 'Suspend on ensure', short = 'ensure' },
  { id = 'cpp_throw', label = 'C++ throw (first chance)', short = 'C++ throw' },
  { id = 'av', label = 'Access violation (first chance)', short = 'AV' },
}
local DEFAULT_ON = { ensure = true, av = true }

local state_file = vim.fn.stdpath('state') .. '/dap-exceptions.json'
local enabled -- set of filter ids

local function load()
  if enabled then return enabled end
  local ok, data = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(state_file), '\n')) end)
  enabled = {}
  for _, f in ipairs(M.FILTERS) do
    if ok and type(data) == 'table' and data[f.id] ~= nil then
      enabled[f.id] = data[f.id] == true
    else
      enabled[f.id] = DEFAULT_ON[f.id] == true
    end
  end
  return enabled
end

local function filter_list()
  local list = {}
  for _, f in ipairs(M.FILTERS) do
    if load()[f.id] then list[#list + 1] = f.id end
  end
  return list
end

--- Applies the settings to new sessions and to the running one.
local function apply()
  local dap = require('dap')
  dap.defaults.dbgeng.exception_breakpoints = filter_list()
  if dap.session() then dap.set_exception_breakpoints(filter_list()) end
  pcall(vim.fn.writefile, { vim.json.encode(load()) }, state_file)
  vim.cmd.redrawstatus({ bang = true })
end

function M.toggle_filter(id)
  load()[id] = not load()[id]
  apply()
  for _, f in ipairs(M.FILTERS) do
    if f.id == id then vim.notify(f.label .. ': ' .. (enabled[id] and 'on' or 'off'), vim.log.levels.INFO, { title = 'Debug' }) end
  end
end

--- Picker over the exception settings; picking one toggles it and reopens the list.
function M.pick_filters()
  vim.ui.select(M.FILTERS, {
    prompt = 'Exception breakpoints (select to toggle)',
    format_item = function(f) return (load()[f.id] and '[x] ' or '[ ] ') .. f.label end,
  }, function(f)
    if not f then return end
    M.toggle_filter(f.id)
    vim.schedule(M.pick_filters)
  end)
end

-- Title bars ---------------------------------------------------------------------------------
local function count_breakpoints()
  local n = 0
  for _, bps in pairs(require('dap.breakpoints').get()) do n = n + #bps end
  return n
end

local function filters_text()
  local parts = {}
  for _, f in ipairs(M.FILTERS) do
    parts[#parts + 1] = f.short .. (load()[f.id] and ' ✓' or ' ✗')
  end
  return table.concat(parts, '  ')
end

local TITLES = {
  dapui_scopes = function() return '%#Title# Variables %*  ⏎/double-click expand · e edit value · r send to REPL' end,
  dapui_stacks = function()
    return '%#Title# Call stack %*  click/⏎ go to frame · t library frames · <leader>dk/dj frame up/down · <leader>dT threads'
  end,
  dapui_breakpoints = function()
    return ('%%#Title# Breakpoints (%d) %%*  click/⏎ go to · t on/off · d delete · F9 toggle  │  %s  (<leader>dx)')
      :format(count_breakpoints(), filters_text())
  end,
  dapui_watches = function() return '%#Title# Watches %*  type an expression + ⏎ to add · e edit · d delete' end,
}

--- Winbar text for a dap-ui panel (evaluated on every redraw).
function M.winbar(ft)
  local f = TITLES[ft]
  return f and f() or ''
end

local function set_winbars(buf)
  local ft = vim.bo[buf].filetype
  if not TITLES[ft] then return end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.wo[win].winbar = ("%%{%%v:lua.require'core.debug_ui'.winbar('%s')%%}"):format(ft)
  end
end

-- dap-ui options --------------------------------------------------------------------------------
function M.dapui_opts()
  return {
    icons = { expanded = '▾', collapsed = '▸', current_frame = '→' },
    mappings = {
      expand = { '<CR>', '<2-LeftMouse>' },
      open = 'o',
      remove = 'd',
      edit = 'e',
      repl = 'r',
      toggle = 't',
    },
    -- a single click opens a frame / breakpoint (the click puts the cursor on the line first)
    element_mappings = {
      stacks = { open = { '<CR>', '<LeftRelease>' }, expand = 'o', toggle = 't' },
      breakpoints = { open = { '<CR>', '<LeftRelease>' }, toggle = 't', remove = 'd' },
    },
    layouts = {
      {
        elements = { { id = 'scopes', size = 0.55 }, { id = 'stacks', size = 0.45 } },
        size = 60,
        position = 'left',
      },
      {
        elements = { { id = 'breakpoints', size = 0.3 }, { id = 'watches', size = 0.2 }, { id = 'repl', size = 0.5 } },
        size = 12,
        position = 'bottom',
      },
    },
    controls = {
      enabled = true,
      element = 'repl',
      icons = {
        pause = '⏸', play = '▶', step_into = '↓', step_over = '↷', step_out = '↑',
        step_back = '↶', run_last = '↻', terminate = '■', disconnect = '⏏',
      },
    },
  }
end

-- signs and title-bar autocmds -------------------------------------------------------------------
function M.setup()
  local function hl_defaults()
    vim.api.nvim_set_hl(0, 'DapBreakpoint', { default = true, link = 'DiagnosticError' })
    vim.api.nvim_set_hl(0, 'DapBreakpointLine', { default = true })
    vim.api.nvim_set_hl(0, 'DapBreakpointCondition', { default = true, link = 'DiagnosticWarn' })
    vim.api.nvim_set_hl(0, 'DapBreakpointRejected', { default = true, link = 'Comment' })
    vim.api.nvim_set_hl(0, 'DapLogPoint', { default = true, link = 'DiagnosticInfo' })
    vim.api.nvim_set_hl(0, 'DapStopped', { default = true, link = 'DiagnosticWarn' })
    vim.api.nvim_set_hl(0, 'DapStoppedLine', { default = true, link = 'Visual' })
  end
  hl_defaults()
  local signs = {
    DapBreakpoint = { text = '●', texthl = 'DapBreakpoint', linehl = 'DapBreakpointLine' },
    DapBreakpointCondition = { text = '◆', texthl = 'DapBreakpointCondition' },
    DapBreakpointRejected = { text = '○', texthl = 'DapBreakpointRejected' },
    DapLogPoint = { text = '◇', texthl = 'DapLogPoint' },
    DapStopped = { text = '→', texthl = 'DapStopped', linehl = 'DapStoppedLine' },
  }
  for name, def in pairs(signs) do vim.fn.sign_define(name, def) end

  local group = vim.api.nvim_create_augroup('core-debug-ui', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = hl_defaults })
  vim.api.nvim_create_autocmd({ 'BufWinEnter', 'FileType' }, {
    group = group,
    callback = function(ev) set_winbars(ev.buf) end,
  })

  require('dap').defaults.dbgeng.exception_breakpoints = filter_list()
end

return M
