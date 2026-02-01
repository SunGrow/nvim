-- =============================================================================
-- Leader & globals
-- =============================================================================
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"
local is_windows = vim.fn.has('win32') == 1 or vim.fn.has('win64') == 1
local has_make = vim.fn.executable('make') == 1

if not has_make then
  vim.notify(
    "telescope-fzf-native.nvim disabled: 'make' executable not found",
    vim.log.levels.WARN
  )
end

-- =============================================================================
-- Editor options
-- =============================================================================
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.mouse = 'a'
vim.opt.showmode = false
vim.opt.clipboard = 'unnamedplus'
vim.opt.breakindent = true
vim.opt.undofile = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.signcolumn = 'yes'
vim.opt.updatetime = 250
vim.opt.timeoutlen = 900
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.list = true
vim.opt.listchars = { tab = '» ', trail = '·', nbsp = '␣' }
vim.opt.inccommand = 'split'
vim.opt.cursorline = true
vim.opt.scrolloff = 4
vim.opt.termguicolors = true

-- Indentation
vim.opt.expandtab = true
vim.opt.shiftwidth = 2
vim.opt.tabstop = 2
vim.opt.softtabstop = 2

-- =============================================================================
-- General keymaps
-- =============================================================================
vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<cr>', { desc = 'Clear search highlight' })
vim.keymap.set('n', '<leader>w', '<C-W>', { desc = 'Enter window mode' })
vim.keymap.set('n', '<leader>e', ':Ex<CR>', { desc = 'Enter file navigation' })

-- =============================================================================
-- Bootstrap lazy.nvim
-- =============================================================================
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

-- =============================================================================
-- Plugin specifications
-- =============================================================================
require("lazy").setup({
  -- ---------------------------------------------------------------------------
  -- Core dependencies
  -- ---------------------------------------------------------------------------
  'nvim-lua/plenary.nvim',
  'nvim-tree/nvim-web-devicons',
  'MunifTanjim/nui.nvim',

  -- ---------------------------------------------------------------------------
  -- UI & Theme
  -- ---------------------------------------------------------------------------
  {
    'catppuccin/nvim',
    name = 'catppuccin',
    lazy = false,
    priority = 1000,
    config = function()
      vim.cmd.colorscheme('catppuccin-latte')
    end,
  },

  -- ---------------------------------------------------------------------------
  -- Telescope
  -- ---------------------------------------------------------------------------
  {
    'nvim-telescope/telescope.nvim',
    branch = '0.1.x',
    dependencies = {
      'nvim-lua/plenary.nvim',
      {
        'nvim-telescope/telescope-fzf-native.nvim',
        build = has_make and 'make' or nil,
        cond = has_make,
      },
    },
    config = function()
      local telescope = require('telescope')
      telescope.setup({
        defaults = {
          mappings = {
            i = {
              ['<C-u>'] = false,
              ['<C-d>'] = false,
            },
          },
        },
      })
      pcall(telescope.load_extension, 'fzf')

      vim.keymap.set('n', '<leader>ff', require('telescope.builtin').find_files, { desc = 'Find files' })
      vim.keymap.set('n', '<leader>fg', require('telescope.builtin').live_grep, { desc = 'Live grep' })
      vim.keymap.set('n', '<leader>fb', require('telescope.builtin').buffers, { desc = 'Buffers' })
      vim.keymap.set('n', '<leader>fh', require('telescope.builtin').help_tags, { desc = 'Help tags' })
    end,
  },

  -- ---------------------------------------------------------------------------
  -- LSP Support
  -- ---------------------------------------------------------------------------
  {
    'neovim/nvim-lspconfig',
    event = { 'BufReadPre', 'BufNewFile' },
    dependencies = {
      'williamboman/mason.nvim',
      'williamboman/mason-lspconfig.nvim',
      'hrsh7th/cmp-nvim-lsp',
      {
        'folke/lazydev.nvim',
        ft = 'lua',
        opts = {
          library = {
            { path = "${3rd}/luv/library", words = { "vim%.uv" } },
          },
          enabled = function(root_dir)
            return vim.g.lazydev_enabled == nil and true or vim.g.lazydev_enabled
          end,
        },
      },
    },
    config = function()
      require('mason').setup()
      require('mason-lspconfig').setup({
        ensure_installed = {
          'lua_ls',
          'clangd',
          'ts_ls',
          'rust_analyzer',
        },
        automatic_installation = true,
      })

      local lspconfig = require('lspconfig')
      local capabilities = require('cmp_nvim_lsp').default_capabilities()

      -- LSP keymaps
      vim.keymap.set('n', 'gD', vim.lsp.buf.declaration, { desc = 'LSP declaration' })
      vim.keymap.set('n', 'gd', vim.lsp.buf.definition, { desc = 'LSP definition' })
      vim.keymap.set('n', 'K', vim.lsp.buf.hover, { desc = 'LSP hover' })
      vim.keymap.set('n', 'gi', vim.lsp.buf.implementation, { desc = 'LSP implementation' })
      vim.keymap.set('n', '<f2>', vim.lsp.buf.rename, { desc = 'LSP rename' })
      vim.keymap.set('n', '<a-cr>', vim.lsp.buf.code_action, { desc = 'LSP code action' })
      vim.keymap.set('n', '<a-]>', vim.lsp.buf.references, { desc = 'LSP references' })
      vim.keymap.set('n', '<as-]>', vim.lsp.buf.outgoing_calls, { desc = 'LSP outgoing calls' })
      vim.keymap.set('n', '<ac-]>', vim.lsp.buf.incoming_calls, { desc = 'LSP incoming calls' })

      lspconfig.lua_ls.setup({
        capabilities = capabilities,
      })

      lspconfig.clangd.setup({
        capabilities = capabilities,
        cmd = {
          'clangd',
          '--background-index',
          '--clang-tidy',
          '--header-insertion=iwyu',
          '--completion-style=detailed',
          '--function-arg-placeholders',
          '--fallback-style=llvm',
          '--suggest-missing-includes',
          '--pch-storage=memory',
          '--cross-file-rename',
        },
        filetypes = { 'c', 'cpp', 'objc', 'objcpp', 'cuda', 'proto' },
        root_dir = lspconfig.util.root_pattern(
          '.clangd',
          '.clang-tidy',
          '.clang-format',
          'clang-format',
          'compile_commands.json',
          'compile_flags.txt',
          'configure.ac',
          '.git'
        ),
        single_file_support = true,
      })

      lspconfig.ts_ls.setup({
        capabilities = capabilities,
        root_dir = lspconfig.util.root_pattern('package.json', 'tsconfig.json', '.git'),
        single_file_support = true,
        settings = {
          typescript = {
            format = {
              indentSize = 2,
            },
          },
          javascript = {
            format = {
              indentSize = 2,
            },
          },
        },
      })

      lspconfig.rust_analyzer.setup({
        capabilities = capabilities,
      })
    end,
  },

  -- ---------------------------------------------------------------------------
  -- Autocompletion & snippets
  -- ---------------------------------------------------------------------------
  {
    'hrsh7th/nvim-cmp',
    event = 'InsertEnter',
    dependencies = {
      'hrsh7th/cmp-nvim-lsp',
      'hrsh7th/cmp-buffer',
      'hrsh7th/cmp-path',
      'L3MON4D3/LuaSnip',
      'saadparwaiz1/cmp_luasnip',
      'rafamadriz/friendly-snippets',
    },
    config = function()
      local cmp = require('cmp')
      local luasnip = require('luasnip')
      require('luasnip.loaders.from_vscode').lazy_load()

      cmp.setup({
        snippet = {
          expand = function(args)
            luasnip.lsp_expand(args.body)
          end,
        },
        mapping = cmp.mapping.preset.insert({
          ['<C-d>'] = cmp.mapping.scroll_docs(-4),
          ['<C-f>'] = cmp.mapping.scroll_docs(4),
          ['<C-Space>'] = cmp.mapping.complete(),
          ['<C-e>'] = cmp.mapping.abort(),
          ['<CR>'] = cmp.mapping.confirm({ select = true }),
          ['<Tab>'] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_next_item()
            elseif luasnip.expand_or_jumpable() then
              luasnip.expand_or_jump()
            else
              fallback()
            end
          end, { 'i', 's' }),
          ['<S-Tab>'] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_prev_item()
            elseif luasnip.jumpable(-1) then
              luasnip.jump(-1)
            else
              fallback()
            end
          end, { 'i', 's' }),
        }),
        sources = {
          { name = 'nvim_lsp' },
          { name = 'luasnip' },
          { name = 'path' },
          { name = 'buffer' },
        },
      })
    end,
  },

  -- ---------------------------------------------------------------------------
  -- Treesitter
  -- ---------------------------------------------------------------------------
  {
    'nvim-treesitter/nvim-treesitter',
    build = ':TSUpdate',
    config = function()
      require('nvim-treesitter.configs').setup({
        highlight = { enable = true },
        indent = { enable = true },
      })
    end,
  },

  -- ---------------------------------------------------------------------------
  -- Git
  -- ---------------------------------------------------------------------------
  {
    'lewis6991/gitsigns.nvim',
    config = true,
  },
  {
    'sindrets/diffview.nvim',
  },

  -- ---------------------------------------------------------------------------
  -- Status line
  -- ---------------------------------------------------------------------------
  {
    'nvim-lualine/lualine.nvim',
    dependencies = { 'nvim-tree/nvim-web-devicons' },
    config = true,
  },

  -- ---------------------------------------------------------------------------
  -- Notifications
  -- ---------------------------------------------------------------------------
  {
    'rcarriga/nvim-notify',
    config = function()
      vim.notify = require('notify')
      require('notify').setup({
        background_colour = '#000000',
        timeout = 3000,
        max_width = 60,
      })
    end,
  },

  -- ---------------------------------------------------------------------------
  -- Debugging
  -- ---------------------------------------------------------------------------
  {
    'rcarriga/nvim-dap-ui',
    dependencies = {
      'mfussenegger/nvim-dap',
      'jay-babu/mason-nvim-dap.nvim',
      'nvim-neotest/nvim-nio',
    },
    config = function()
      require('mason-nvim-dap').setup({
        ensure_installed = { 'codelldb' },
        automatic_installation = true,
      })

      local dap, dapui = require('dap'), require('dapui')
      local mason_registry = require('mason-registry')
      local codelldb = mason_registry.get_package('codelldb')
      local extension_path = codelldb:get_install_path() .. '/extension/'
      local codelldb_path = extension_path .. 'adapter/codelldb'
      if is_windows then
        codelldb_path = codelldb_path .. '.exe'
      end

      dap.adapters.codelldb = {
        type = 'server',
        port = '${port}',
        executable = {
          command = codelldb_path,
          args = { '--port', '${port}' },
          detached = false,
        },
      }

      dap.configurations.cpp = {
        {
          name = 'Launch file',
          type = 'codelldb',
          request = 'launch',
          program = function()
            return vim.fn.input('Path to executable: ', vim.fn.getcwd() .. '/', 'file')
          end,
          cwd = '${workspaceFolder}',
          stopOnEntry = false,
          args = {},
          runInTerminal = false,
        },
      }

      dap.configurations.c = dap.configurations.cpp

      dapui.setup({
        layouts = {
          {
            elements = {
              { id = 'scopes', size = 0.25 },
              'breakpoints',
              'stacks',
              'watches',
            },
            size = 40,
            position = 'left',
          },
          {
            elements = {
              'repl',
              'console',
            },
            size = 0.25,
            position = 'bottom',
          },
        },
      })

      dap.listeners.after.event_initialized['dapui_config'] = function()
        dapui.open()
      end
      dap.listeners.before.event_terminated['dapui_config'] = function()
        dapui.close()
      end
      dap.listeners.before.event_exited['dapui_config'] = function()
        dapui.close()
      end

      vim.keymap.set('n', '<leader>dt', dap.toggle_breakpoint, { desc = 'Toggle Breakpoint' })
      vim.keymap.set('n', '<f5>', dap.continue, { desc = 'Continue' })
      vim.keymap.set('n', '<f10>', dap.step_over, { desc = 'Step Over' })
      vim.keymap.set('n', '<f11>', dap.step_into, { desc = 'Step Into' })
      vim.keymap.set('n', '<s-f11>', dap.step_out, { desc = 'Step Out' })
      vim.keymap.set('n', '<leader>du', dapui.toggle, { desc = 'Toggle UI' })
      vim.keymap.set('n', '<M-k>', dapui.eval, { desc = 'Evaluate under cursor' })
      vim.keymap.set('v', '<M-k>', dapui.eval, { desc = 'Evaluate selection' })
    end,
  },

  -- ---------------------------------------------------------------------------
  -- Formatting
  -- ---------------------------------------------------------------------------
  {
    'stevearc/conform.nvim',
    opts = {
      formatters_by_ft = {
        lua = { 'stylua' },
        javascript = { { 'prettierd', 'prettier' } },
        typescript = { { 'prettierd', 'prettier' } },
        cpp = { 'clang-format' },
        c = { 'clang-format' },
        python = { 'black' },
        rust = { 'rustfmt' },
      },
      format_on_save = false,
      formatters = {
        clang_format = {
          args = {
            '--style={IndentWidth: 2, ColumnLimit: 100, AllowShortFunctionsOnASingleLine: Empty}',
          },
        },
      },
    },
    config = function(_, opts)
      require('conform').setup(opts)
      vim.keymap.set('n', '<leader>f', function()
        require('conform').format({ async = true, lsp_fallback = true })
      end, { desc = 'Format buffer' })
    end,
  },

  -- ---------------------------------------------------------------------------
  -- Markdown
  -- ---------------------------------------------------------------------------
  {
    'OXY2DEV/markview.nvim',
    lazy = false,
    dependencies = {
      'nvim-treesitter/nvim-treesitter',
      'nvim-tree/nvim-web-devicons',
    },
  },

  -- ---------------------------------------------------------------------------
  -- Task runner
  -- ---------------------------------------------------------------------------
  {
    'stevearc/overseer.nvim',
    dependencies = {
      'nvim-telescope/telescope.nvim',
      'rcarriga/nvim-notify',
    },
    cmd = {
      'OverseerOpen',
      'OverseerClose',
      'OverseerToggle',
      'OverseerSaveBundle',
      'OverseerLoadBundle',
      'OverseerDeleteBundle',
      'OverseerRunCmd',
      'OverseerRun',
      'OverseerInfo',
      'OverseerBuild',
      'OverseerQuickAction',
      'OverseerTaskAction',
    },
    config = function()
      require('overseer').setup({
        templates = { 'builtin' },
        task_list = {
          direction = 'right',
          min_width = 50,
          max_width = 80,
          bindings = {
            ['?'] = 'ShowHelp',
            ['<CR>'] = 'RunAction',
            ['<C-e>'] = 'Edit',
            ['o'] = 'Open',
            ['<C-v>'] = 'OpenVsplit',
            ['<C-s>'] = 'OpenSplit',
            ['<C-f>'] = 'OpenFloat',
            ['<C-q>'] = 'OpenQuickfix',
            ['p'] = 'TogglePreview',
            ['<C-l>'] = 'IncreaseDetail',
            ['<C-h>'] = 'DecreaseDetail',
            ['L'] = 'IncreaseAllDetail',
            ['H'] = 'DecreaseAllDetail',
            ['['] = 'DecreaseWidth',
            [']'] = 'IncreaseWidth',
            ['{'] = 'PrevTask',
            ['}'] = 'NextTask',
          },
        },
      })

      vim.keymap.set('n', '<leader>oo', '<cmd>OverseerToggle<CR>', { desc = 'Toggle Overseer' })
      vim.keymap.set('n', '<leader>or', '<cmd>OverseerRun<CR>', { desc = 'Run Overseer Task' })
      vim.keymap.set('n', '<leader>ob', '<cmd>OverseerBuild<CR>', { desc = 'Build Overseer Task' })
      vim.keymap.set('n', '<leader>oa', '<cmd>OverseerQuickAction<CR>', { desc = 'Overseer Quick Action' })
    end,
  },

  -- ---------------------------------------------------------------------------
  -- Workflow coaching
  -- ---------------------------------------------------------------------------
  {
    'm4xshen/hardtime.nvim',
    dependencies = { 'MunifTanjim/nui.nvim', 'nvim-lua/plenary.nvim' },
    opts = {
      max_time = 1000,
      max_count = 3,
      disable_mouse = true,
      hint = true,
      notification = true,
      allow_different_key = true,
      enabled = true,
      restricted_keys = {
        ['h'] = { 'n', 'x' },
        ['j'] = { 'n', 'x' },
        ['k'] = { 'n', 'x' },
        ['l'] = { 'n', 'x' },
        ['-'] = { 'n', 'x' },
        ['+'] = { 'n', 'x' },
        ['gj'] = { 'n', 'x' },
        ['gk'] = { 'n', 'x' },
        ['<CR>'] = { 'n', 'x' },
        ['<C-M>'] = { 'n', 'x' },
        ['<C-N>'] = { 'n', 'x' },
        ['<C-P>'] = { 'n', 'x' },
      },
      disabled_keys = {
        ['<Up>'] = {},
        ['<Down>'] = {},
        ['<Left>'] = {},
        ['<Right>'] = {},
      },
      disabled_filetypes = { 'qf', 'netrw', 'NvimTree', 'lazy', 'mason', 'oil' },
    },
  },

  -- ---------------------------------------------------------------------------
  -- Context reminders
  -- ---------------------------------------------------------------------------
  {
    'Hashino/doing.nvim',
    config = function()
      require('doing').setup({
        message_timeout = 2000,
        winbar = {
          enabled = true,
          ignored_buffers = { 'NvimTree' },
        },
        doing_prefix = 'Current Task: ',
        store = {
          auto_create_file = true,
          file_name = '.tasks',
        },
      })
      vim.api.nvim_set_hl(0, 'WinBar', { link = 'Search' })
    end,
  },
})
