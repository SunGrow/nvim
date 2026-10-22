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
  { id = 'cpp_throw', label = 'C++ throw (first chance)', short = 'throw' },
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
  vim.cmd.redrawtabline()
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
M.state = { ensure_stop = false } -- runtime state, kept across config reloads (core.reload); ensure_stop: stopped on a failed ensure

local function where(loc)
  return vim.fn.fnamemodify(loc.path, ':t') .. ':' .. loc.line
end

--- Stopped on an ensure: that ensure no longer suspends (this and later sessions).
function M.ignore_current_ensure()
  local session = require('dap').session()
  local thread = session and session.stopped_thread_id and session.threads[session.stopped_thread_id]
  local top = thread and thread.frames and thread.frames[1]
  if not M.state.ensure_stop or not (top and top.source and top.source.path) then
    return vim.notify('Not stopped on an ensure', vim.log.levels.WARN, { title = 'Debug' })
  end
  load()
  local loc = { path = top.source.path, line = top.line }
  for _, l in ipairs(ignored) do
    if l.path:lower() == loc.path:lower() and l.line == loc.line then return end
  end
  ignored[#ignored + 1] = loc
  M.state.ensure_stop = false -- the button goes away once used
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

--- The session's adapter type ('dbgeng', 'codelldb', ...); without a session, the one F5 would start.
local function adapter()
  local s = package.loaded['dap'] and require('dap').session()
  if s then return s.config.type end
  local ctx = require('core.context')
  return (ctx.is_ue or ctx.wsl_ue) and 'dbgeng' or 'codelldb'
end

--- The debugger is (or F5 would start) dbgeng-dap: Unreal on Windows, also from WSL.
function M.dbgeng() return adapter() == 'dbgeng' end

--- Exception settings as clickable checkboxes ("󰄲 ensure  󰄱 C++ throw  󰄲 AV  2 ignored").
--- They are dbgeng-dap's filters: empty for other debuggers.
local function filter_boxes(labels)
  if adapter() ~= 'dbgeng' then return '' end
  local parts = {}
  for _, f in ipairs(M.FILTERS) do
    local on = load()[f.id]
    parts[#parts + 1] = ('%%#%s#%%0@v:lua._debug_ui.%s@%s %s%%X%%*'):format(
      on and 'DapUIDebugOnBox' or 'DapUIDebugOffBox', f.id, on and '󰄲' or '󰄱', labels and f.label or f.short)
  end
  if #ignored > 0 then parts[#parts + 1] = ('%%0@v:lua._debug_ui.pick@%d ignored%%X'):format(#ignored) end
  return table.concat(parts, labels and '  ' or ' ')
end

--- Capabilities of the running debug adapter (dbgeng-dap: no "set variable", no logpoints).
local function caps()
  local s = package.loaded['dap'] and require('dap').session()
  return s and s.capabilities or {}
end

-- Panel title bars: what the panel is, then its keys. Each returns the title and the hints, most
-- needed first; `M.winbar` keeps as many hints as the panel width holds (Neovim's `%<` cut the hints
-- at their start: "Call stack <lick/⏎ open frame").
local TITLES = {
  dapui_breakpoints = function()
    -- the exception checkboxes, also in the toolbar: "󰄲 ensure 󰄱 throw 󰄲 AV"; the count goes first
    -- when they do not fit beside it (a 160-column screen)
    local boxes = filter_boxes(false)
    return ('Breakpoints (%d)'):format(count_breakpoints()), { boxes ~= '' and boxes or nil }, 'Breakpoints'
  end,
  dapui_scopes = function()
    return 'Variables', { '⏎ expand', caps().supportsSetVariable and 'e edit' or nil, '? keys' }
  end,
  dapui_stacks = function() return 'Call stack', { 'click/⏎ open frame', '? keys' } end,
  dapui_watches = function() return 'Watches', { 'i add', 'd delete', '? keys' } end,
  ['dap-repl'] = function()
    -- codelldb's console is in lldb's "commands" mode: `?expr` evaluates, the rest are lldb commands
    if adapter() == 'codelldb' then return 'Debug console', { '?expr evaluates', 'lldb commands', '? keys' } end
    return 'Debug console', { 'type an expression, ⏎ evaluates', '? keys' }
  end,
}

--- Display width of statusline text (highlight, click and %% codes take no cells).
local function stl_width(s)
  s = s:gsub('%%#[^#]*#', ''):gsub('%%%*', ''):gsub('%%%d*@[^@]*@', ''):gsub('%%X', ''):gsub('%%%%', '%%')
  return vim.fn.strdisplaywidth(s)
end

-- Every debugger key, in the order a newcomer needs them: the toolbar, `?` and F1 are made from this.
-- key: as shown; lhs: the mapping (checked by the F1 sheet); ue: dbgeng-dap only (Unreal on Windows, also from WSL).
M.KEYS = {
  { key = 'F5', lhs = '<F5>', desc = 'Start debugging / continue' },
  { key = 'F6', lhs = '<F6>', desc = 'Pause' },
  { key = 'Shift+F5', lhs = '<S-F5>', desc = 'Stop' },
  { key = 'Ctrl+Shift+F5', lhs = '<C-S-F5>', desc = 'Restart' },
  { key = 'F10', lhs = '<F10>', desc = 'Step over' },
  { key = 'F11', lhs = '<F11>', desc = 'Step into' },
  { key = 'Shift+F11', lhs = '<S-F11>', desc = 'Step out' },
  { key = 'Ctrl+F10', lhs = '<C-F10>', desc = 'Run to cursor' },
  {},
  { key = 'F9', lhs = '<F9>', desc = 'Breakpoint on / off' },
  { key = 'Click gutter', lhs = '<LeftMouse>', desc = 'Breakpoint on / off (line numbers)' },
  { key = 'Space dB', lhs = '<leader>dB', desc = 'Breakpoint with a condition' },
  { key = 'Space dL', lhs = '<leader>dL', desc = 'List all breakpoints' },
  { key = 'Space dC', lhs = '<leader>dC', desc = 'Delete all breakpoints' },
  { key = 'Space dx', lhs = '<leader>dx', desc = 'Stop on: ensure, C++ throw, AV', ue = true },
  { key = 'Space dI', lhs = '<leader>dI', desc = 'Ignore this ensure from now on', ue = true },
  {},
  { key = 'Space dh', lhs = '<leader>dh', desc = 'Value under the cursor' },
  { key = 'Space de', lhs = '<leader>de', desc = 'Evaluate an expression' },
  { key = 'Space dw', lhs = '<leader>dw', desc = 'Add to Watches' },
  { key = 'Space dk / dj', lhs = '<leader>dk', desc = 'Call stack: caller / back' },
  { key = 'Space dT', lhs = '<leader>dT', desc = 'All threads' },
  { key = 'Space du', lhs = '<leader>du', desc = 'Show / hide debugger panels' },
}

local PANEL_HELP = {
  'In the panels',
  '  Call stack    click / ⏎ go to the frame · t show/hide library frames',
  '  Breakpoints   click / ⏎ go to it · t enable/disable · d delete · click a checkbox to toggle an exception',
  '  Variables     ⏎ / double-click expand · r copy to the console',
  '  Watches       i type an expression, ⏎ adds it · d delete · ⏎ expand',
  '  Console       an expression or a debugger command, ⏎ runs it (codelldb: ?expr evaluates)',
}

--- Lines for the debugger key list (`?` in the panels, <leader>d?, and the F1 sheet).
function M.help_lines()
  local lines = {}
  local ue = M.dbgeng()
  for _, k in ipairs(M.KEYS) do
    if not k.ue or ue then lines[#lines + 1] = k.key and ('  %-15s %s'):format(k.key, k.desc) or '' end
  end
  lines[#lines + 1] = ''
  vim.list_extend(lines, PANEL_HELP)
  if caps().supportsSetVariable then lines[#lines + 1] = '  Variables     e edit a value' end
  return lines
end

--- Floating list of the debugger keys (`?` in any debugger panel, <leader>d?).
function M.help()
  require('core.keyhelp').float('Debugger keys', M.help_lines())
end

--- Winbar text for a dap-ui panel (evaluated on every redraw).
function M.winbar(ft)
  local f = TITLES[ft]
  if not f then return '' end
  local title, hints, short = f()
  local win = vim.g.statusline_winid or 0
  local width = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win) or 80
  -- the title at the left edge, in line with the panel's text, then three spaces before the hints
  if short and hints[1] and stl_width(hints[1]) > width - #title - 3 then title = short end
  local room = width - #title - 3
  local kept = {}
  for i = 1, table.maxn(hints) do
    local h = hints[i]
    if h then
      local text = table.concat(vim.list_extend(vim.list_slice(kept), { h }), ' · ')
      if stl_width(text) > room then break end
      kept[#kept + 1] = h
    end
  end
  local tail = #kept > 0 and ('   ' .. table.concat(kept, ' · ')) or ''
  return '%#Title#' .. title .. '%*' .. tail
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
    -- the toolbar is the tabline while debugging (M.toolbar)
    controls = { enabled = false },
  }
end

--- Config hot reload (core.reload): signs, listeners and toolbar again; dap-ui's panel options
--- (layouts, keys, icons) too when no debug session runs.
function M.on_reload()
  M.setup()
  local dap = package.loaded['dap']
  if package.loaded['dapui'] and not (dap and dap.session()) then
    require('dapui').setup(M.dapui_opts())
  end
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
-- While a session runs, the tabline (top row, whole width) is the debugger toolbar, like Rider's: what
-- the program is doing, then named buttons with their keys (click or press the key), then the exception
-- checkboxes. dap-ui's own controls (bare ▶ ↓ ↷ ↑ ↶ ↻ ■ ⏏ icons in the console title, two of them not
-- supported by dbgeng-dap) are off.
_G._debug_ui = {}
for _, f in ipairs(M.FILTERS) do
  _G._debug_ui[f.id] = function() M.toggle_filter(f.id) end
end
_G._debug_ui.ignore_ensure = function() M.ignore_current_ensure() end
_G._debug_ui.pick = function() M.pick_filters() end
_G._debug_ui.help = function() M.help() end
_G._debug_ui.continue = function() require('dap').continue() end
_G._debug_ui.pause = function() require('dap').pause() end
_G._debug_ui.step_over = function() require('dap').step_over() end
_G._debug_ui.step_into = function() require('dap').step_into() end
_G._debug_ui.step_out = function() require('dap').step_out() end
_G._debug_ui.run_to_cursor = function() M.run_to_cursor() end
_G._debug_ui.restart = function() M.restart() end
_G._debug_ui.stop = function() M.stop() end

-- id, name, short name, key, available when: 'stopped' | 'running' | 'any'
local BUTTONS = {
  { 'continue', 'Continue', 'Continue', 'F5', 'stopped' },
  { 'pause', 'Pause', 'Pause', 'F6', 'running' },
  { 'step_over', 'Step over', 'Over', 'F10', 'stopped' },
  { 'step_into', 'Step into', 'Into', 'F11', 'stopped' },
  { 'step_out', 'Step out', 'Out', 'Shift+F11', 'stopped' },
  { 'run_to_cursor', 'Run to cursor', 'To cursor', 'Ctrl+F10', 'stopped' },
  { 'restart', 'Restart', 'Restart', 'Ctrl+Shift+F5', 'any' },
  { 'stop', 'Stop', 'Stop', 'Shift+F5', 'any' },
  { 'help', 'All keys', 'Keys', '?', 'any' },
}

local REASONS = { breakpoint = 'at a breakpoint', step = 'after a step', pause = 'paused by you',
  entry = 'at the program start', exception = 'on an exception', ['function breakpoint'] = 'at a breakpoint',
  ['goto'] = 'at the cursor' }

--- "Paused at a breakpoint in add_points (demo.c:8)" / "Running"; plain text and highlight group.
--- where = false leaves out the function and file (narrow screens; the code shows them anyway).
local function state_text(session, where)
  if not session.stopped_thread_id then return ' ▶ Running ', 'DapToolbarRunning' end
  local why = M.state.ensure_stop and 'on a failed ensure()' or REASONS[M.state.stop_reason or ''] or 'paused'
  local f = session.current_frame
  local loc = ''
  if f and where then
    local file = f.source and f.source.path and vim.fn.fnamemodify(f.source.path, ':t')
    loc = ' in ' .. (f.name or '?'):gsub('%(.*', '') .. (file and (' (%s:%d)'):format(file, f.line) or '')
  end
  return ' 󰏤 Paused ' .. why .. loc .. ' ', 'DapToolbarPaused'
end

--- Tabline while debugging: the state, then the buttons usable now (paused: no Pause; running: no
--- steps). It shrinks to fit: the location goes first, then the long names, then the keys.
function M.toolbar()
  local ok, dap = pcall(require, 'dap')
  local session = ok and dap.session()
  if not session then return '' end
  local stopped = session.stopped_thread_id ~= nil
  local cols = vim.o.columns
  local function render(tier, where)
    local state, state_hl = state_text(session, where)
    local out, width = { ('%%#%s#%s%%*'):format(state_hl, state) }, vim.fn.strdisplaywidth(state)
    if M.state.ensure_stop then
      local t = ' Ignore this ensure '
      out[#out + 1] = ' %#DapUIDebugIgnoreBtn#%0@v:lua._debug_ui.ignore_ensure@' .. t .. '%X%*'
      width = width + #t + 1
    end
    for _, b in ipairs(BUTTONS) do
      if b[5] == 'any' or (b[5] == 'stopped') == stopped then
        -- 1 "Step over F10"  2 "Over F10"  3 "Over F10", "Out" (keys only for plain F-keys)  4 "Over"  5 "F10"
        local plain = b[4]:match('^F%d+$') or b[4] == '?'
        local label = tier == 1 and (b[2] .. ' ' .. b[4]) or tier == 2 and (b[3] .. ' ' .. b[4])
          or tier == 3 and (plain and (b[3] .. ' ' .. b[4]) or b[3]) or tier == 4 and b[3] or b[4]
        out[#out + 1] = (' %%#DapToolbarButton#%%0@v:lua._debug_ui.%s@ %s %%X%%*'):format(b[1], label)
        width = width + vim.fn.strdisplaywidth(label) + 3
      end
    end
    return table.concat(out), width
  end
  local bar, width
  for _, try in ipairs({ { 1, true }, { 1, false }, { 2, true }, { 2, false }, { 3, false }, { 4, false }, { 5, false } }) do
    bar, width = render(try[1], try[2])
    if width <= cols then break end
  end
  -- the exception checkboxes when there is room (they are in the Breakpoints title as well)
  local boxes = filter_boxes(true)
  local boxes_width = vim.fn.strdisplaywidth(vim.api.nvim_eval_statusline(boxes, { use_tabline = true }).str)
  if width + boxes_width + 4 <= cols then
    bar = bar .. '%#TabLineFill#%=' .. boxes .. ' '
  else
    bar = bar .. '%#TabLineFill#'
  end
  return bar
end

local function show_toolbar(on)
  if on and not M.state.toolbar then
    M.state.toolbar = { showtabline = vim.o.showtabline, tabline = vim.o.tabline }
    vim.o.tabline = "%!v:lua.require'core.debug_ui'.toolbar()"
    vim.o.showtabline = 2
  elseif not on and M.state.toolbar then
    vim.o.showtabline = M.state.toolbar.showtabline
    vim.o.tabline = M.state.toolbar.tabline
    M.state.toolbar = nil
  end
  vim.cmd.redrawtabline()
end

function M.run_to_cursor()
  local dap = require('dap')
  if not (dap.session() and dap.session().stopped_thread_id) then
    return vim.notify('Run to cursor: the program is not paused', vim.log.levels.WARN, { title = 'Debug' })
  end
  M.state.to_cursor = true
  dap.run_to_cursor()
end

function M.stop()
  if require('ue.run').available() then return require('ue.run').stop() end
  require('dap').terminate()
end

--- Restart: stop, then start the same thing again (UE: builds the selected configuration first).
function M.restart()
  local dap = require('dap')
  local ue = require('ue.run').available()
  if not dap.session() then
    if ue then return require('ue.run').debug() end
    return dap.run_last()
  end
  if not ue then return dap.restart() end
  dap.terminate({ on_done = function() vim.schedule(function() require('ue.run').debug() end) end })
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
    vim.api.nvim_set_hl(0, 'DapToolbarPaused', { default = true, link = 'DiffChange' })
    vim.api.nvim_set_hl(0, 'DapToolbarRunning', { default = true, link = 'DiffAdd' })
    vim.api.nvim_set_hl(0, 'DapToolbarButton', { default = true, link = 'TabLineSel' })
    vim.api.nvim_set_hl(0, 'DapToolbarOff', { default = true, link = 'TabLine' })
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
  dap.listeners.after.event_initialized['debug_ui'] = function(session)
    send_ignored(session)
    vim.schedule(function() show_toolbar(true) end)
  end
  dap.listeners.after.event_stopped['debug_ui'] = function(_, body)
    M.state.ensure_stop = body ~= nil and body.description == 'ensure() failed' -- dbgeng-dap's ensure stop
    -- run to cursor stops on a temporary breakpoint: say "at the cursor"
    M.state.stop_reason = M.state.to_cursor and 'goto' or (body and body.reason)
    M.state.to_cursor = false
    vim.schedule(repaint)
  end
  -- the toolbar's "in add_points (demo.c:8)" follows the selected frame
  dap.listeners.after.stackTrace['debug_ui_toolbar'] = function() vim.schedule(repaint) end
  for _, ev in ipairs({ 'event_terminated', 'event_exited', 'disconnect' }) do
    dap.listeners.after[ev]['debug_ui_toolbar'] = function()
      vim.schedule(function()
        if not dap.session() then show_toolbar(false) end
      end)
    end
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
      if M.state.ensure_stop then
        M.state.ensure_stop = false
        vim.schedule(repaint)
      end
    end
  end
end

return M
