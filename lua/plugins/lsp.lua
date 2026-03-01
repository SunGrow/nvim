-- Use centralized project context detection
local is_ue_project = require('core.context').is_ue

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
    local ok, blink = pcall(require, 'blink.cmp')
    local capabilities = ok and blink.get_lsp_capabilities() or {}

    -- Configure lua_ls via Neovim 0.11 native API
    vim.lsp.config('lua_ls', {
      capabilities = capabilities,
    })

    -- Build clangd command (UE-aware)
    local clangd_cmd = {
      'clangd',
      '--background-index',
      '--background-index-priority=background',
      '--completion-style=detailed',
      '--function-arg-placeholders=false',
      '-j=8',
      '--limit-results=500',
    }
    if is_ue_project then
      -- UE: no header insertion (iwyu breaks .generated.h include order),
      -- no clang-tidy (.clangd removes all checks anyway, saves init time),
      -- disk PCH storage (UE PCH files are 100MB+, memory mode causes OOM)
      vim.list_extend(clangd_cmd, {
        '--header-insertion=never',
        '--pch-storage=disk',
      })
    else
      vim.list_extend(clangd_cmd, {
        '--clang-tidy',
        '--header-insertion=iwyu',
        '--pch-storage=memory',
      })
    end

    -- Configure clangd for C++
    -- NOTE: --offset-encoding removed — Neovim 0.11 negotiates encoding natively
    vim.lsp.config('clangd', {
      capabilities = capabilities,
      cmd = clangd_cmd,
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

        -- clangd-specific: register ClangdSwitchSourceHeader command (used by <M-o>)
        local clangd = vim.lsp.get_clients({ bufnr = event.buf, name = 'clangd' })[1]
        if clangd then
          vim.api.nvim_buf_create_user_command(event.buf, 'ClangdSwitchSourceHeader', function()
            local params = { uri = vim.uri_from_bufnr(event.buf) }
            clangd:request('textDocument/switchSourceHeader', params, function(err, result)
              if err or not result or result == '' then return end
              vim.cmd.edit(vim.uri_to_fname(result))
            end, event.buf)
          end, { desc = 'Switch between source/header (clangd)' })
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
