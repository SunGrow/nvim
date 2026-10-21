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
          ensure_installed = { 'codelldb' },
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
    keys = {
      { '<leader>db', function() require('dap').toggle_breakpoint() end, desc = 'Toggle breakpoint' },
      { '<leader>dB', function() require('dap').set_breakpoint(vim.fn.input('Breakpoint condition: ')) end, desc = 'Conditional breakpoint' },
      { '<leader>dc', function() require('dap').continue() end, desc = 'Continue / Start' },
      { '<leader>di', function() require('dap').step_into() end, desc = 'Step into' },
      { '<leader>do', function() require('dap').step_over() end, desc = 'Step over' },
      { '<leader>dO', function() require('dap').step_out() end, desc = 'Step out' },
      { '<leader>dr', function() require('dap').repl.toggle() end, desc = 'Toggle REPL' },
      { '<leader>dl', function() require('dap').run_last() end, desc = 'Run last' },
      { '<leader>dt', function() require('dap').terminate() end, desc = 'Terminate' },
      { '<leader>du', function() require('dapui').toggle() end, desc = 'Toggle DAP UI' },
      { '<leader>de', function() require('dapui').eval() end, desc = 'Eval expression', mode = { 'n', 'v' } },
      { '<leader>dh', function() require('dap.ui.widgets').hover() end, desc = 'Hover value under cursor', mode = { 'n', 'v' } },
      { '<leader>dk', function() require('dap').up() end, desc = 'Frame up (caller)' },
      { '<leader>dj', function() require('dap').down() end, desc = 'Frame down (callee)' },
      { '<leader>dT', function()
        local w = require('dap.ui.widgets')
        w.centered_float(w.threads)
      end, desc = 'Threads (all suspended threads and their stacks)' },
      { '<leader>dx', function() require('core.debug_ui').pick_filters() end, desc = 'Exception breakpoints (ensure, C++ throw, AV)' },
      { '<leader>dE', function() require('core.debug_ui').toggle_filter('ensure') end, desc = 'Toggle suspend on ensure' },
      { '<leader>dI', function() require('core.debug_ui').ignore_current_ensure() end, desc = 'Ignore this ensure (others still suspend)' },
      -- UE projects: with no session, F5 builds and debugs the selected run configuration (lua/ue/run.lua)
      { '<F5>', function()
        local dap = require('dap')
        if not dap.session() and require('core.context').is_ue then return require('ue.run').debug() end
        dap.continue()
      end, desc = 'Debug: Start / Continue' },
      { '<S-F5>', function()
        if require('core.context').is_ue then return require('ue.run').stop() end
        require('dap').terminate()
      end, desc = 'Debug: Stop' },
      { '<F9>', function() require('dap').toggle_breakpoint() end, desc = 'Debug: Toggle breakpoint' },
      { '<F10>', function() require('dap').step_over() end, desc = 'Debug: Step over' },
      { '<F11>', function() require('dap').step_into() end, desc = 'Debug: Step into' },
      { '<S-F11>', function() require('dap').step_out() end, desc = 'Debug: Step out' },
    },
  },
}
