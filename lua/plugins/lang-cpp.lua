-- Generic C++ development support: DAP (debugging)
-- Loads only when a C/C++ file is opened or debug keys are pressed
return {
  {
    'mfussenegger/nvim-dap',
    dependencies = {
      {
        'rcarriga/nvim-dap-ui',
        dependencies = { 'nvim-neotest/nvim-nio' },
        -- Unicode icons, titled panels with key hints, click to open (lua/core/debug_ui.lua)
        opts = function() return require('core.debug_ui').dapui_opts() end,
      },
      {
        -- variable values as end-of-line virtual text while stopped (works with any adapter: codelldb, dbgeng)
        'theHamsta/nvim-dap-virtual-text',
        opts = {
          virt_text_pos = 'eol',
          highlight_changed_variables = true,
          -- hide not-yet-live locals (DbgEng: "Value unavailable error for X") instead of printing noise
          display_callback = function(variable)
            local v = (variable.value or ''):gsub('%s+', ' ')
            if v:find('Value unavailable', 1, true) then return nil end
            return variable.name .. ' = ' .. v
          end,
        },
      },
      {
        'jay-babu/mason-nvim-dap.nvim',
        dependencies = { 'mason-org/mason.nvim' },
        opts = {
          -- codelldb ships as a zip: on Linux Mason needs `unzip` (WSL Ubuntu: sudo apt install unzip);
          -- without it, asking would fail with an error on every start
          ensure_installed = (vim.fn.has('win32') == 1 or vim.fn.executable('unzip') == 1) and { 'codelldb' } or {},
        },
      },
    },
    config = function()
      local dap = require('dap')
      local dapui = require('dapui')
      require('core.debug_ui').setup() -- signs, panel title bars, exception settings

      -- In UE projects, UDB.nvim handles DAP adapter + launch configurations
      -- with auto-discovered engine binaries. Skip generic setup.
      local is_ue = require('core.context').is_ue

      if not is_ue then
        -- codelldb adapter (Windows-aware)
        local codelldb_cmd = vim.fn.exepath('codelldb')
        if codelldb_cmd == '' then
          local mason_bin = vim.fn.stdpath('data') .. '/mason/bin/'
          codelldb_cmd = mason_bin .. (vim.fn.has('win32') == 1 and 'codelldb.cmd' or 'codelldb')
        end

        dap.adapters.codelldb = {
          type = 'server',
          port = '${port}',
          executable = {
            command = codelldb_cmd,
            args = { '--port', '${port}' },
            detached = vim.fn.has('win32') == 0,
          },
        }

        -- Default C/C++ launch configurations
        dap.configurations.cpp = {
          {
            name = 'Launch executable',
            type = 'codelldb',
            request = 'launch',
            program = function()
              return vim.fn.input('Path to executable: ', vim.fn.getcwd() .. '/', 'file')
            end,
            cwd = '${workspaceFolder}',
            stopOnEntry = false,
          },
          {
            name = 'Attach to process',
            type = 'codelldb',
            request = 'attach',
            pid = require('dap.utils').pick_process,
          },
        }
        dap.configurations.c = dap.configurations.cpp
      else
        -- UE: DbgEng (WinDbg engine) adapter from tools/dbgeng-dap (or $DBGENG_DAP_PATH).
        -- PDB + Unreal.natvis aware; UDB launches use it via adapter_type = 'dbgeng' (lang-ue.lua).
        local dbgeng_dap = vim.env.DBGENG_DAP_PATH
          or vim.fs.normalize(vim.fn.stdpath('config') .. '/tools/dbgeng-dap/dbgeng-dap.py')
        if vim.uv.fs_stat(dbgeng_dap) then
          dap.adapters.dbgeng = { type = 'executable', command = 'python', args = { '-I', dbgeng_dap } }
          dap.configurations.cpp = {
            {
              name = 'Attach to UnrealEditor',
              type = 'dbgeng',
              request = 'attach',
              processId = function() return require('dap.utils').pick_process({ filter = 'UnrealEditor' }) end,
            },
          }
        end
      end

      -- Auto open/close DAP UI on debug sessions (universal)
      dap.listeners.before.attach.dapui_config = function() dapui.open() end
      dap.listeners.before.launch.dapui_config = function() dapui.open() end
      dap.listeners.before.event_terminated.dapui_config = function() dapui.close() end
      dap.listeners.before.event_exited.dapui_config = function() dapui.close() end
    end,
    -- stylua: ignore
    -- F-keys as in Rider's VS Code keymap; the Space d menu names the F-key that does the same.
    -- The toolbar, `?` and F1 list them from core/debug_ui.lua M.KEYS: keep that table in step.
    keys = {
      { '<leader>db', function() require('dap').toggle_breakpoint() end, desc = 'Breakpoint on this line (F9)' },
      { '<leader>dB', function()
        vim.ui.input({ prompt = 'Stop only when (e.g. i == 3): ' }, function(cond)
          if cond and cond ~= '' then require('dap').set_breakpoint(cond) end
        end)
      end, desc = 'Breakpoint with a condition' },
      { '<leader>dL', function() require('dap').list_breakpoints(true) end, desc = 'List all breakpoints' },
      { '<leader>dC', function()
        require('dap').clear_breakpoints()
        vim.notify('All breakpoints deleted', vim.log.levels.INFO, { title = 'Debug' })
      end, desc = 'Delete all breakpoints' },
      { '<leader>dc', function() require('dap').continue() end, desc = 'Continue / start (F5)' },
      { '<leader>dp', function() require('dap').pause() end, desc = 'Pause (F6)' },
      { '<leader>do', function() require('dap').step_over() end, desc = 'Step over (F10)' },
      { '<leader>di', function() require('dap').step_into() end, desc = 'Step into (F11)' },
      { '<leader>dO', function() require('dap').step_out() end, desc = 'Step out (Shift+F11)' },
      { '<leader>dg', function() require('core.debug_ui').run_to_cursor() end, desc = 'Run to cursor (Ctrl+F10)' },
      { '<leader>dt', function() require('core.debug_ui').stop() end, desc = 'Stop (Shift+F5)' },
      { '<leader>dR', function() require('core.debug_ui').restart() end, desc = 'Restart (Ctrl+Shift+F5)' },
      { '<leader>dl', function() require('dap').run_last() end, desc = 'Debug the last program again' },
      { '<leader>dr', function() require('dap').repl.toggle() end, desc = 'Debug console' },
      { '<leader>du', function() require('dapui').toggle() end, desc = 'Show / hide debugger panels' },
      { '<leader>de', function() require('dapui').eval() end, desc = 'Evaluate expression (or selection)', mode = { 'n', 'v' } },
      { '<leader>dh', function() require('dap.ui.widgets').hover() end, desc = 'Value under the cursor', mode = { 'n', 'v' } },
      { '<leader>dw', function()
        local expr = vim.fn.mode():match('[vV]') and table.concat(vim.fn.getregion(vim.fn.getpos('v'), vim.fn.getpos('.')), ' ')
          or vim.fn.expand('<cexpr>')
        require('dapui').elements.watches.add(expr)
        vim.notify('Watching ' .. expr, vim.log.levels.INFO, { title = 'Debug' })
      end, desc = 'Add to Watches (word / selection)', mode = { 'n', 'v' } },
      { '<leader>dk', function() require('dap').up() end, desc = 'Call stack: go to the caller' },
      { '<leader>dj', function() require('dap').down() end, desc = 'Call stack: back down' },
      { '<leader>dT', function()
        local w = require('dap.ui.widgets')
        w.centered_float(w.threads)
      end, desc = 'Threads (all suspended threads and their stacks)' },
      { '<leader>dx', function() require('core.debug_ui').pick_filters() end, desc = 'Exceptions: ensure, C++ throw, AV' },
      { '<leader>dE', function() require('core.debug_ui').toggle_filter('ensure') end, desc = 'Stop on failed ensure() on / off' },
      { '<leader>dI', function() require('core.debug_ui').ignore_current_ensure() end, desc = 'Ignore this ensure (others still stop)' },
      { '<leader>d?', function() require('core.debug_ui').help() end, desc = 'All debugger keys' },
      -- UE projects: with no session, F5 builds and debugs the selected run configuration (lua/ue/run.lua)
      { '<F5>', function()
        local dap = require('dap')
        if not dap.session() and require('core.context').is_ue then return require('ue.run').debug() end
        dap.continue()
      end, desc = 'Debug: Start / Continue' },
      { '<F6>', function() require('dap').pause() end, desc = 'Debug: Pause' },
      { '<S-F5>', function() require('core.debug_ui').stop() end, desc = 'Debug: Stop' },
      { '<C-S-F5>', function() require('core.debug_ui').restart() end, desc = 'Debug: Restart' },
      { '<F9>', function() require('dap').toggle_breakpoint() end, desc = 'Debug: Toggle breakpoint' },
      { '<F10>', function() require('dap').step_over() end, desc = 'Debug: Step over' },
      { '<C-F10>', function() require('core.debug_ui').run_to_cursor() end, desc = 'Debug: Run to cursor' },
      { '<F11>', function() require('dap').step_into() end, desc = 'Debug: Step into' },
      { '<S-F11>', function() require('dap').step_out() end, desc = 'Debug: Step out' },
    },
  },
}
