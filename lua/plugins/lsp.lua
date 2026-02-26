return {
  'neovim/nvim-lspconfig',
  event = { 'BufReadPre', 'BufNewFile' },
  dependencies = {
    { 'mason-org/mason.nvim', opts = {} },
    {
      'mason-org/mason-lspconfig.nvim',
      opts = {
        ensure_installed = { 'lua_ls', 'clangd' },
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

    -- Configure clangd for C++ (optimized for large codebases)
    vim.lsp.config('clangd', {
      capabilities = capabilities,
      cmd = {
        'clangd',
        '--background-index',
        '--background-index-priority=background',
        '--clang-tidy',
        '--header-insertion=iwyu',
        '--completion-style=detailed',
        '--function-arg-placeholders=false',
        '--pch-storage=memory',
        '-j=8',
        '--limit-results=500',
        '--offset-encoding=utf-8',
      },
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

        -- clangd-specific: switch between header and source
        -- (manual implementation — ClangdSwitchSourceHeader only exists via nvim-lspconfig)
        local clangd = vim.lsp.get_clients({ bufnr = event.buf, name = 'clangd' })[1]
        if clangd then
          vim.api.nvim_buf_create_user_command(event.buf, 'ClangdSwitchSourceHeader', function()
            local params = { uri = vim.uri_from_bufnr(event.buf) }
            clangd:request('textDocument/switchSourceHeader', params, function(err, result)
              if err or not result or result == '' then return end
              vim.cmd.edit(vim.uri_to_fname(result))
            end, event.buf)
          end, { desc = 'Switch between source/header (clangd)' })
          map('<leader>lh', '<cmd>ClangdSwitchSourceHeader<CR>', 'Switch header/source')
        end

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
