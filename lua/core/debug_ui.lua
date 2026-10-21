-- Debugger UI (nvim-dap-ui) set up to read like Rider's debug tool window:
--   * plain Unicode icons and signs: the terminal font (Cascadia Mono) has no Nerd Font glyphs, and
--     dap-ui's defaults are Nerd Font private-use characters that show as "?"
--   * every panel has a title bar with its main keys; `?` in a panel lists all debugger keys
--   * a click opens a frame or breakpoint (dap-ui's default is <CR> / double-click only)
--   * breakpoints are the top panel, with a count and the exception settings in its title
--   * exception settings ("Suspend on ensure", C++ throw, access violation) are checkboxes in the
--     toolbar (click) and in the Breakpoints title, toggled with <leader>dx / <leader>dE too, and kept
--     across sessions (stdpath('state')/dap-exceptions.json)
--   * stopped on an ensure, "Ignore this ensure" (toolbar button, <leader>dI) stops suspending on that
--     one ensure only, like Rider; <leader>dx lists the ignored ones to bring them back
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
local ignored -- list of { path, line }: ensures that do not suspend

local function load()
  if enabled then return enabled end
  local ok, data = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(state_file), '\n')) end)
  ignored = ok and type(data) == 'table' and type(data.ignored_ensures) == 'table' and data.ignored_ensures or {}
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

--- Repaints the toolbar and the panel title bars now (they show the exception settings).
local function repaint()
  local ok, controls = pcall(require, 'dapui.controls')
  if ok then controls.refresh_control_panel() end
  vim.cmd.redrawstatus({ bang = true })
  pcall(vim.api.nvim__redraw, { winbar = true, flush = true })
end

local function save()
  local data = vim.deepcopy(load())
  data.ignored_ensures = ignored
  pcall(vim.fn.writefile, { vim.json.encode(data) }, state_file)
end

--- Sends the ignored ensures to a dbgeng-dap session (custom request dbgengIgnoreEnsures).
local function send_ignored(session)
  if session and session.config.type == 'dbgeng' then
    load()
    session:request('dbgengIgnoreEnsures', { locations = ignored }, function() end)
  end
end

--- Applies the settings to new sessions and to the running one.
local function apply()
  local dap = require('dap')
  dap.defaults.dbgeng.exception_breakpoints = filter_list()
  if dap.session() then
    dap.set_exception_breakpoints(filter_list())
    send_ignored(dap.session())
  end
  save()
  repaint()
end

-- Ignored ensures ------------------------------------------------------------------------------
local ensure_stop = false -- the session is stopped on a failed ensure

local function where(loc)
  return vim.fn.fnamemodify(loc.path, ':t') .. ':' .. loc.line
end

--- Stopped on an ensure: that ensure no longer suspends (this and later sessions).
function M.ignore_current_ensure()
  local session = require('dap').session()
  local thread = session and session.stopped_thread_id and session.threads[session.stopped_thread_id]
  local top = thread and thread.frames and thread.frames[1]
  if not ensure_stop or not (top and top.source and top.source.path) then
    return vim.notify('Not stopped on an ensure', vim.log.levels.WARN, { title = 'Debug' })
  end
  load()
  local loc = { path = top.source.path, line = top.line }
  for _, l in ipairs(ignored) do
    if l.path:lower() == loc.path:lower() and l.line == loc.line then return end
  end
  ignored[#ignored + 1] = loc
  ensure_stop = false -- the button goes away once used
  apply()
  vim.notify(('Ensure at %s will not suspend again (F5 continues; <leader>dx brings it back)'):format(where(loc)),
    vim.log.levels.INFO, { title = 'Debug' })
end

function M.unignore(i)
  load()
  local loc = table.remove(ignored, i)
  if loc then
    apply()
    vim.notify('Ensure at ' .. where(loc) .. ' suspends again', vim.log.levels.INFO, { title = 'Debug' })
  end
end

function M.toggle_filter(id)
  load()[id] = not load()[id]
  apply()
  for _, f in ipairs(M.FILTERS) do
    if f.id == id then vim.notify(f.label .. ': ' .. (enabled[id] and 'on' or 'off'), vim.log.levels.INFO, { title = 'Debug' }) end
  end
end

--- Picker over the exception settings and the ignored ensures; picking an item toggles it (an
--- ignored ensure suspends again) and reopens the list.
function M.pick_filters()
  load()
  local items = {}
  for _, f in ipairs(M.FILTERS) do items[#items + 1] = { filter = f } end
  for i, loc in ipairs(ignored) do items[#items + 1] = { ignored = i, loc = loc } end
  vim.ui.select(items, {
    prompt = 'Exception breakpoints (select to toggle)',
    format_item = function(it)
      if it.filter then return (load()[it.filter.id] and '[x] ' or '[ ] ') .. it.filter.label end
      return '[ignored ensure] ' .. where(it.loc) .. '  (select to suspend on it again)'
    end,
  }, function(it)
    if not it then return end
    if it.filter then M.toggle_filter(it.filter.id) else M.unignore(it.ignored) end
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
  if #ignored > 0 then parts[#parts + 1] = ('%d ignored'):format(#ignored) end
  return table.concat(parts, '  ')
end

-- Short enough for a 60-column panel; %< drops the tail first when a panel is narrower.
local TITLES = {
  dapui_breakpoints = function()
    return ('%%#Title# Breakpoints (%d) %%*%%<  %s'):format(count_breakpoints(), filters_text())
  end,
  dapui_scopes = function() return '%#Title# Variables %*%<  ⏎ expand · e edit · ? keys' end,
  dapui_stacks = function() return '%#Title# Call stack %*%<  click/⏎ open frame · ? keys' end,
  dapui_watches = function() return '%#Title# Watches %*%<  ⏎ add · e edit · d delete · ? keys' end,
}

local HELP = {
  'Debugger keys',
  '',
  '  F5           start (build + debug) / continue',
  '  Shift+F5     stop',
  '  F10          step over',
  '  F11          step into',
  '  Shift+F11    step out',
  '  F9           toggle breakpoint     <leader>dB  conditional breakpoint',
  '',
  '  Call stack   click / Enter: go to frame   t: show/hide library frames',
  '               <leader>dk / <leader>dj: frame up (caller) / down',
  '  Threads      <leader>dT: all threads and their stacks',
  '  Breakpoints  click / Enter: go to   t: enable/disable   d: delete',
  '  Exceptions   <leader>dx: pick (ensure, C++ throw, access violation, ignored ensures)',
  '               <leader>dE: toggle Suspend on ensure',
  '               <leader>dI: ignore this ensure (stopped on one; others still suspend)',
  '  Variables    Enter / double-click: expand   e: edit   r: send to REPL',
  '  Evaluate     <leader>de: expression (also visual)   <leader>dh: value under cursor',
  '  Panels       <leader>du: show/hide   <leader>dr: REPL',
  '',
  'q / Esc closes this window',
}

--- Floating list of the debugger keys (`?` in any debugger panel).
function M.help()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, HELP)
  vim.bo[buf].modifiable = false
  local width = 0
  for _, l in ipairs(HELP) do width = math.max(width, vim.fn.strdisplaywidth(l)) end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', style = 'minimal', border = 'rounded', title = ' Debug ', title_pos = 'center',
    width = width + 2, height = #HELP,
    row = math.floor((vim.o.lines - #HELP) / 2), col = math.floor((vim.o.columns - width) / 2),
  })
  vim.api.nvim_buf_add_highlight(buf, -1, 'Title', 0, 0, -1)
  for _, key in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', key, function() vim.api.nvim_win_close(win, true) end, { buffer = buf, nowait = true })
  end
end

--- Winbar text for a dap-ui panel (evaluated on every redraw).
function M.winbar(ft)
  local f = TITLES[ft]
  return f and f() or ''
end

local function set_winbars(buf)
  local ft = vim.bo[buf].filetype
  if ft:match('^dapui_') or ft == 'dap-repl' then
    vim.keymap.set('n', '?', M.help, { buffer = buf, desc = 'Debugger keys' })
  end
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
    -- sizes are screen fractions, so the panels keep their share when the terminal or font size changes
    layouts = {
      {
        elements = { { id = 'breakpoints', size = 0.2 }, { id = 'scopes', size = 0.45 }, { id = 'stacks', size = 0.35 } },
        size = 0.25,
        position = 'left',
      },
      {
        elements = { { id = 'watches', size = 0.3 }, { id = 'repl', size = 0.7 } },
        size = 0.2,
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

--- Resets the open dap-ui layouts to their configured proportions (after a terminal resize).
function M.relayout()
  local ok, windows = pcall(require, 'dapui.windows')
  if not ok then return end
  for _, layout in ipairs(windows.layouts or {}) do
    if layout:is_open() then layout:resize({ reset = true }) end
  end
end

-- toolbar -----------------------------------------------------------------------------------------
-- dap-ui's controls (▶ ↓ ↷ ↑ ...) get the exception settings as clickable checkboxes, like Rider's
-- "Suspend on ensure" toggle next to its debugger buttons.
_G._debug_ui = {}
for _, f in ipairs(M.FILTERS) do
  _G._debug_ui[f.id] = function() M.toggle_filter(f.id) end
end

_G._debug_ui.ignore_ensure = function() M.ignore_current_ensure() end
_G._debug_ui.pick = function() M.pick_filters() end

function M.toolbar_checkboxes()
  local parts = {}
  if ensure_stop then
    parts[#parts + 1] = '%#DapUIDebugIgnoreBtn#%0@v:lua._debug_ui.ignore_ensure@ Ignore this ensure %X%*'
  end
  for _, f in ipairs(M.FILTERS) do
    local on = load()[f.id]
    parts[#parts + 1] = ('%%#%s#%%0@v:lua._debug_ui.%s@%s %s%%X%%*'):format(
      on and 'DapUIDebugOnBox' or 'DapUIDebugOffBox', f.id, on and '[x]' or '[ ]',
      f.id == 'ensure' and 'Suspend on ensure' or f.short)
  end
  if #ignored > 0 then
    parts[#parts + 1] = ('%%0@v:lua._debug_ui.pick@%d ignored%%X'):format(#ignored)
  end
  return '   │  ' .. table.concat(parts, '   ') .. '   │  ? keys'
end

local function hook_controls()
  local ok, controls = pcall(require, 'dapui.controls')
  if not ok or controls._debug_ui_hooked then return end
  controls._debug_ui_hooked = true
  local orig = controls.controls
  controls.controls = function(is_active) return orig(is_active) .. M.toolbar_checkboxes() end
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
    vim.api.nvim_set_hl(0, 'DapUIDebugOnBox', { default = true, link = 'DiagnosticOk' })
    vim.api.nvim_set_hl(0, 'DapUIDebugOffBox', { default = true, link = 'Comment' })
    vim.api.nvim_set_hl(0, 'DapUIDebugIgnoreBtn', { default = true, link = 'DiffChange' })
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

  local dap = require('dap')
  dap.defaults.dbgeng.exception_breakpoints = filter_list()
  hook_controls()
  dap.listeners.after.event_initialized['debug_ui'] = function(session) send_ignored(session) end
  dap.listeners.after.event_stopped['debug_ui'] = function(_, body)
    ensure_stop = body ~= nil and body.description == 'ensure() failed' -- dbgeng-dap's ensure stop
    vim.schedule(repaint)
  end
  -- clangd needs 40-50 s for a UE file's first parse: start it for the call stack's project files when the
  -- debugger stops, so clicking a frame shows a parsed file (nearest frames first, top frame is opened anyway)
  dap.listeners.after.stackTrace['debug_ui'] = function(_, err, response, request)
    if err or not response or (request and (request.startFrame or 0) > 0) then return end
    local files, seen = {}, {}
    for _, f in ipairs(response.stackFrames or {}) do
      local path = f.source and f.source.path
      if path and not seen[path] and (f.source.presentationHint ~= 'deemphasize') then
        seen[path] = true
        files[#files + 1] = path
      end
    end
    vim.schedule(function() require('core.clangd').prewarm(files, 'dap') end)
  end
  for _, ev in ipairs({ 'event_terminated', 'event_exited' }) do
    dap.listeners.after[ev]['debug_ui_clangd'] = function() require('core.clangd').release('dap') end
  end
  for _, ev in ipairs({ 'event_continued', 'event_terminated', 'event_exited', 'continue' }) do
    dap.listeners.after[ev]['debug_ui'] = function()
      if ensure_stop then
        ensure_stop = false
        vim.schedule(repaint)
      end
    end
  end
end

return M
