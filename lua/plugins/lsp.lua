return {
  'neovim/nvim-lspconfig',
  event = { 'BufReadPre', 'BufNewFile' },
  dependencies = {
    { 'mason-org/mason.nvim', opts = {} },
    {
      'mason-org/mason-lspconfig.nvim',
      opts = {
        ensure_installed = { 'lua_ls' },
        automatic_enable = true,
      },
    },
    { 'saghen/blink.cmp' },
    {
      'folke/lazydev.nvim',
      ft = 'lua',
      opts = {
        library = {
          { path = '${3rd}/luv/library', words = { 'vim%.uv' } },
        },
      },
    },
  },
  config = function()
    -- Pass blink.cmp capabilities to all LSP servers
    local capabilities = require('blink.cmp').get_lsp_capabilities()

    -- Configure lua_ls via Neovim 0.11 native API
    vim.lsp.config('lua_ls', {
      capabilities = capabilities,
    })

    -- LspAttach: buffer-local keymaps for non-default bindings
    vim.api.nvim_create_autocmd('LspAttach', {
      group = vim.api.nvim_create_augroup('lsp-attach', { clear = true }),
      callback = function(event)
        local map = function(keys, func, desc, mode)
          mode = mode or 'n'
          vim.keymap.set(mode, keys, func, { buffer = event.buf, desc = 'LSP: ' .. desc })
        end

        map('gd', vim.lsp.buf.definition, 'Go to definition')
        map('gD', vim.lsp.buf.declaration, 'Go to declaration')
        map('<leader>ld', vim.diagnostic.open_float, 'Diagnostics float')
        map('<leader>li', '<cmd>LspInfo<CR>', 'LSP info')

        -- Built-in 0.11 defaults (NOT overridden):
        -- grn = rename, gra = code action (n,v), grr = references
        -- gri = implementation, grt = type definition, gO = document symbols
        -- K = hover, <C-s> = signature help (i,s)
        -- CTRL-] = definition (via tagfunc), gq = format (via formatexpr)
        -- [d/]d = prev/next diagnostic, <C-W>d = diagnostic float
      end,
    })
  end,
}
