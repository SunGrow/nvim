-- Generic C++ development support: DAP (debugging)
-- Loads only when a C/C++ file is opened or debug keys are pressed
return {
  {
    'mfussenegger/nvim-dap',
    dependencies = {
      {
        'rcarriga/nvim-dap-ui',
        dependencies = { 'nvim-neotest/nvim-nio' },
        opts = {},
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

      -- Auto open/close DAP UI on debug sessions
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
      { '<F5>', function() require('dap').continue() end, desc = 'Debug: Continue' },
      { '<F9>', function() require('dap').toggle_breakpoint() end, desc = 'Debug: Toggle breakpoint' },
      { '<F10>', function() require('dap').step_over() end, desc = 'Debug: Step over' },
      { '<F11>', function() require('dap').step_into() end, desc = 'Debug: Step into' },
      { '<S-F11>', function() require('dap').step_out() end, desc = 'Debug: Step out' },
    },
  },
}
