return {
  'lewis6991/gitsigns.nvim',
  event = { 'BufReadPre', 'BufNewFile' },
  opts = {
    on_attach = function(bufnr)
      local gs = require('gitsigns')
      local map = function(mode, l, r, desc)
        vim.keymap.set(mode, l, r, { buffer = bufnr, desc = 'Git: ' .. desc })
      end

      -- Hunk navigation (nav_hunk replaces deprecated next_hunk/prev_hunk)
      map('n', ']h', function() gs.nav_hunk('next') end, 'Next hunk')
      map('n', '[h', function() gs.nav_hunk('prev') end, 'Previous hunk')

      -- Hunk actions
      map('n', '<leader>gs', gs.stage_hunk, 'Stage hunk')
      map('n', '<leader>gr', gs.reset_hunk, 'Reset hunk')
      map('v', '<leader>gs', function() gs.stage_hunk({ vim.fn.line('.'), vim.fn.line('v') }) end, 'Stage hunk')
      map('v', '<leader>gr', function() gs.reset_hunk({ vim.fn.line('.'), vim.fn.line('v') }) end, 'Reset hunk')
      map('n', '<leader>gp', gs.preview_hunk, 'Preview hunk')
      map('n', '<leader>gb', function() gs.blame_line({ full = true }) end, 'Blame line')
      map('n', '<leader>gd', gs.diffthis, 'Diff this')
    end,
  },
}
