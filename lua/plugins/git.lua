return {
  {
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
        map('n', '<leader>gP', gs.preview_hunk_inline, 'Preview hunk inline')
        map('n', '<leader>gw', gs.toggle_word_diff, 'Toggle word diff')
        map('n', '<leader>gb', function() gs.blame_line({ full = true }) end, 'Blame line')
        map('n', '<leader>gd', gs.diffthis, 'Diff this')
        map('n', '<leader>gL', gs.toggle_current_line_blame, 'Toggle inline blame')
        map('n', '<leader>gq', function() gs.setqflist('all') end, 'All changes to quickfix')
        -- the whole file annotated with commits; Enter / double-click opens one (core/git_history.lua)
        map('n', '<leader>ga', function()
          require('core.git_history')
          vim.cmd('Gitsigns blame')
        end, 'Annotate file (blame panel)')
      end,
    },
  },

  -- Side-by-side history and diffs (Rider's Git log / file history / commit diff / merge tool)
  {
    'sindrets/diffview.nvim',
    cmd = { 'DiffviewOpen', 'DiffviewFileHistory', 'DiffviewClose' },
    -- stylua: ignore
    keys = {
      { '<leader>gh', '<cmd>DiffviewFileHistory %<CR>', desc = 'Git: History of this file (diffview)' },
      { '<leader>gh', ":'<,'>DiffviewFileHistory<CR>", mode = 'x', desc = 'Git: History of these lines (diffview)' },
      { '<leader>gH', '<cmd>DiffviewFileHistory<CR>', desc = 'Git: History of the repository (diffview)' },
      { '<leader>gD', '<cmd>DiffviewOpen<CR>', desc = 'Git: All changes side by side / merge conflicts (diffview)' },
      { '<leader>go', function() require('core.git_history').line_commit() end, desc = 'Git: Open the commit of this line (diffview)' },
    },
    opts = function()
      local close = { 'n', 'q', '<cmd>DiffviewClose<CR>', { desc = 'Close diffview' } }
      return {
        enhanced_diff_hl = true,
        view = { merge_tool = { layout = 'diff3_mixed' } },
        keymaps = { view = { close }, file_panel = { close }, file_history_panel = { close } },
      }
    end,
    config = function(_, opts)
      require('diffview').setup(opts)
      -- Closing a view (q) while its first commit's files load: the loader then scroll-syncs the closed
      -- windows and raises "Invalid window id" (scene/layout.lua:286, diffview 4516612; q 0.7 s after
      -- <leader>gh). Skip the sync when a window is gone.
      local Layout = require('diffview.scene.layout').Layout
      local sync_scroll = Layout.sync_scroll
      function Layout:sync_scroll(...)
        for _, w in ipairs(self.windows or {}) do
          if not (w.id and vim.api.nvim_win_is_valid(w.id)) then return end
        end
        return sync_scroll(self, ...)
      end
    end,
  },
}
