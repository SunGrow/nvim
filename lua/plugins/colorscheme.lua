return {
  'catppuccin/nvim',
  name = 'catppuccin',
  lazy = false,
  priority = 1000,
  config = function()
    vim.cmd.colorscheme('catppuccin-latte')

    vim.keymap.set('n', '<leader>ut', function()
      if vim.o.background == 'light' then
        vim.cmd.colorscheme('catppuccin-mocha')
      else
        vim.cmd.colorscheme('catppuccin-latte')
      end
    end, { desc = 'Toggle light/dark theme' })
  end,
}
