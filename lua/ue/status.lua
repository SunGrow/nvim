-- Statusline indicator for UNL's background work (project index, asset scans), so it is visible
-- whether the UE tooling is busy, ready or down:
--   "UE ⠋ indexing 42%"  full refresh (first open of a project, VCS change), with progress
--   "UE ⠋ scanning"      asset scan / file updates / other server work
--   "UE ⠋ compile db"    clangd's compile_commands.json being regenerated (ue/compiledb.lua)
--   "UE ✓"               idle: index ready
--   "UE 󰅖"               server not reachable
-- Server state comes from UNL.status (polls the server's cheap simple_status); the percentage
-- comes from UNL's refresh progress events through the global event hook (UNL.status itself uses
-- the per-category hook, so both coexist).
local M = {}

local SPIN = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local BUSY_LABEL = {
  refreshing = 'indexing', scanning = 'scanning', updating = 'updating', busy = 'busy',
}
-- Per-keystroke completion and query traffic is not worth a spinner.
local QUIET = { idle = true, completing = true, querying = true }

local started = false
local refresh = nil -- { aggr, pct } while a refresh reports progress

local function hook_progress()
  local ok_ev, events = pcall(require, 'UNL.backend.progress.events')
  local ok_ag, Aggregator = pcall(require, 'UNL.backend.progress.aggregator')
  if not (ok_ev and ok_ag) then return end
  events.set_global_hook(function(ev)
    if ev.purpose ~= 'refresh' then return end
    if ev.phase == 'define_from_plan' then
      refresh = { aggr = Aggregator.new() }
      refresh.aggr:define_from_plan(ev.phases or {})
    elseif ev.phase == 'define' then
      refresh = refresh or { aggr = Aggregator.new() }
      refresh.aggr:define(ev.stage, ev.total)
    elseif ev.phase == 'stage_update' then
      refresh = refresh or { aggr = Aggregator.new() }
      if not refresh.aggr.stages[ev.stage] then refresh.aggr:define(ev.stage, ev.total) end
      refresh.aggr:update(ev.stage, ev.done, ev.total)
    elseif ev.phase == 'finish' then
      refresh = nil
      require('UNL.status').refresh() -- poll now instead of waiting for the next tick
    end
  end)
end

local function ensure_started()
  if started then return true end
  local ok, unl_status = pcall(require, 'UNL.status')
  if not ok then return false end
  started = true
  unl_status.start({ interval_ms = 2000 })
  hook_progress()
  return true
end

local function state()
  if not ensure_started() then return 'offline' end
  local st = require('UNL.status').get_state().server_state
  if refresh then return 'refreshing' end
  return st
end

local function cdb_busy()
  local cdb = package.loaded['ue.compiledb']
  return cdb ~= nil and cdb.busy()
end

function M.text()
  local st = state()
  local frame = SPIN[(math.floor(vim.uv.now() / 120) % #SPIN) + 1]
  if cdb_busy() and (st == 'offline' or QUIET[st]) then return 'UE ' .. frame .. ' compile db' end
  if st == 'offline' then return 'UE 󰅖' end
  if QUIET[st] then return 'UE ✓' end
  local label = BUSY_LABEL[st] or st
  if st == 'refreshing' and refresh then
    return ('UE %s %s %d%%'):format(frame, label, refresh.aggr:percentage())
  end
  return ('UE %s %s'):format(frame, label)
end

function M.color()
  local st = state()
  if cdb_busy() then return { fg = '#e0af68' } end
  if st == 'offline' then return { fg = '#f7768e' } end
  if QUIET[st] then return { fg = '#9ece6a' } end
  return { fg = '#e0af68' }
end

--- True while something is running, so the statusline can redraw faster for the spinner.
function M.busy()
  local st = state()
  return cdb_busy() or (st ~= 'offline' and not QUIET[st])
end

return M
