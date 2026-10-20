-- Avoid vim.fn.executable('make') at startup (~28-60 ms on Windows PATH scans):
-- if the fzf-native library is already built, a file stat is enough. `make` is only probed
-- when the library is missing (fresh install) so lazy.nvim can still build it.
local fzf_dir = vim.fn.stdpath('data') .. '/lazy/telescope-fzf-native.nvim/build/'
local fzf_built = vim.uv.fs_stat(fzf_dir .. 'libfzf.dll') ~= nil
  or vim.uv.fs_stat(fzf_dir .. 'libfzf.so') ~= nil
  or vim.uv.fs_stat(fzf_dir .. 'libfzf.dylib') ~= nil
local use_fzf = fzf_built or vim.fn.executable('make') == 1

return {
  'nvim-telescope/telescope.nvim',
  branch = '0.1.x',
  dependencies = {
    'nvim-lua/plenary.nvim',
    { 'nvim-tree/nvim-web-devicons' },
    {
      'nvim-telescope/telescope-fzf-native.nvim',
      build = function(plugin)
        if vim.fn.executable('make') == 1 then
          vim.system({ 'make' }, { cwd = plugin.dir }):wait()
        end
      end,
      cond = use_fzf,
    },
  },
  keys = {
    { '<leader>ff', function()
        if require('core.context').is_ue then
          vim.cmd('UEP files')
        else
          require('telescope.builtin').find_files()
        end
      end, desc = 'Find files' },
    { '<leader>fg', function()
        if require('core.context').is_ue then
          vim.cmd('UEP grep')
        else
          require('telescope.builtin').live_grep()
        end
      end, desc = 'Live grep' },
    { '<leader>fb', function() require('telescope.builtin').buffers() end, desc = 'Buffers' },
    { '<leader>fh', function() require('telescope.builtin').help_tags() end, desc = 'Help tags' },
    { '<leader>fd', function() require('telescope.builtin').diagnostics() end, desc = 'Diagnostics' },
    { '<leader>fr', function() require('telescope.builtin').resume() end, desc = 'Resume last' },
    { '<leader>fo', function() require('telescope.builtin').oldfiles() end, desc = 'Recent files' },
    { '<leader>fw', function() require('telescope.builtin').grep_string() end, desc = 'Grep word' },
  },
  config = function()
    local telescope = require('telescope')
    telescope.setup({
      defaults = {
        preview = {
          -- Prevent previewer crashes from invalid third-party Treesitter queries.
          treesitter = false,
        },
        mappings = {
          i = {
            ['<C-u>'] = false,
            ['<C-d>'] = false,
          },
        },
      },
    })
    pcall(telescope.load_extension, 'fzf')
  end,
}
