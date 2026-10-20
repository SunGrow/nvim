-- Headless nvim-dap smoke test for dbgeng-dap (does not load or modify any user config).
--   nvim --headless --clean -l tests/nvim_smoke.lua <nvim-dap dir> <log file> <program> [args...]
-- Launches <program> with stopOnEntry, checks stopped(entry) + threads + stackTrace + repl passthrough,
-- then continues until the program exits.
local nvim_dap_dir, log_path, program = arg[1], arg[2], arg[3]
local prog_args = {}
for i = 4, #arg do prog_args[#prog_args + 1] = arg[i] end
vim.opt.rtp:prepend(nvim_dap_dir)

local here = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2))))
local log = assert(io.open(log_path, 'w'))
local t0 = vim.uv.hrtime()
local function L(m)
  log:write(string.format('%8.2fs  %s\n', (vim.uv.hrtime() - t0) / 1e9, m))
  log:flush()
end
local function oneline(v) return (vim.inspect(v):gsub('%s+', ' ')) end

local dap = require('dap')
dap.adapters.dbgeng = {
  type = 'executable',
  command = 'python',
  args = { '-I', here .. '/dbgeng-dap.py', '--log', log_path .. '.adapter.log' },
}
local seen = {}
local finished = false
dap.listeners.after.event_initialized.smoke = function() L('event initialized'); seen.initialized = true end
dap.listeners.after.event_stopped.smoke = function(session, body)
  L('event stopped reason=' .. tostring(body.reason) .. ' thread=' .. tostring(body.threadId))
  seen.stopped = body.reason
  session:request('threads', {}, function(err, resp)
    L('threads: ' .. (err and tostring(err.message) or (#resp.threads .. ' threads, first=' .. resp.threads[1].name)))
    seen.threads = (not err) and #resp.threads > 0
    session:request('stackTrace', { threadId = body.threadId, levels = 5 }, function(err2, st)
      if err2 then
        L('stackTrace error ' .. tostring(err2.message))
      else
        for _, f in ipairs(st.stackFrames) do L('  frame ' .. f.name) end
        seen.stack = #st.stackFrames > 0
      end
      session:request('evaluate', { expression = '`lm m python*', context = 'repl' }, function(err3, ev)
        L('repl `lm m python*: ' .. (err3 and tostring(err3.message) or (ev.result:gsub('\n', ' | '))))
        seen.repl = not err3
        dap.continue()
      end)
    end)
  end)
end
dap.listeners.after.event_output.smoke = function(_, body)
  if body.category == 'stdout' then L('stdout: ' .. vim.trim(body.output)) end
end
dap.listeners.after.event_exited.smoke = function(_, body)
  L('event exited code=' .. tostring(body.exitCode))
  seen.exited = body.exitCode
end
dap.listeners.after.event_terminated.smoke = function()
  L('event terminated')
  seen.terminated = true
  vim.defer_fn(function() finished = true end, 1000)
end

L('dap.run ' .. program)
dap.run({ type = 'dbgeng', request = 'launch', name = 'smoke', program = program, args = prog_args,
          stopOnEntry = true, cwd = vim.fs.dirname(program) })
-- `nvim -l` exits when this chunk returns: keep the event loop running until the session ended
if not vim.wait(120000, function() return finished end, 50) then
  L('FAIL timeout ' .. oneline(seen))
else
  local ok = seen.initialized and seen.stopped == 'entry' and seen.threads and seen.stack and seen.repl
    and seen.exited ~= nil and seen.terminated
  L((ok and 'PASS' or 'FAIL') .. ' nvim-dap smoke ' .. oneline(seen))
end
log:close()
