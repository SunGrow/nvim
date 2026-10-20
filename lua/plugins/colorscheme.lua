-- Default theme: catppuccin-latte. Any other theme picked with <leader>uc (or :colorscheme) is
-- remembered in stdpath('state')/colorscheme and restored at the next start.
-- colors/rider-denis-dark.lua is Rider's "Denis Dark" editor scheme.
local DEFAULT = 'catppuccin-latte'

local function state_file()
  return vim.fn.stdpath('state') .. '/colorscheme'
end

local function saved()
  local ok, lines = pcall(vim.fn.readfile, state_file())
  return ok and lines[1] and lines[1] ~= '' and lines[1] or nil
end

return {
  'catppuccin/nvim',
  name = 'catppuccin',
  lazy = false,
  priority = 1000,
  config = function()
    if not pcall(vim.cmd.colorscheme, saved() or DEFAULT) then
      vim.cmd.colorscheme(DEFAULT)
    end

    vim.api.nvim_create_autocmd('ColorScheme', {
      group = vim.api.nvim_create_augroup('RememberColorscheme', { clear = true }),
      callback = function(args)
        -- Telescope's live preview fires ColorScheme for every entry; save only when it settles.
        vim.schedule(function()
          if vim.g.colors_name == args.match then
            pcall(vim.fn.writefile, { args.match }, state_file())
          end
        end)
      end,
    })

    vim.keymap.set('n', '<leader>uc', function()
      require('telescope.builtin').colorscheme({ enable_preview = true })
    end, { desc = 'Choose theme' })

    vim.keymap.set('n', '<leader>ut', function()
      if vim.o.background == 'light' then
        vim.cmd.colorscheme('catppuccin-mocha')
      else
        vim.cmd.colorscheme('catppuccin-latte')
      end
    end, { desc = 'Toggle light/dark theme' })
  end,
}
