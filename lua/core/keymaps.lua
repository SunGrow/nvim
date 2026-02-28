-- =============================================================================
-- Leader keys (must be set before lazy.nvim)
-- =============================================================================
vim.g.mapleader = ' '
vim.g.maplocalleader = '\\'

-- =============================================================================
-- General keymaps
-- =============================================================================
local map = vim.keymap.set

-- Clear search highlight
map('n', '<Esc>', '<cmd>nohlsearch<CR>', { desc = 'Clear search highlight' })

-- Window management
map('n', '<leader>w', '<C-W>', { desc = 'Window mode' })

-- File explorer (netrw)
map('n', '<leader>e', ':Ex<CR>', { desc = 'File explorer' })

-- Quick save
map('n', '<leader>s', '<cmd>w<CR>', { desc = 'Save file' })

-- Buffer navigation
map('n', '<S-h>', '<cmd>bprevious<CR>', { desc = 'Previous buffer' })
map('n', '<S-l>', '<cmd>bnext<CR>', { desc = 'Next buffer' })

-- Better movement on wrapped lines
map('n', 'j', "v:count == 0 ? 'gj' : 'j'", { expr = true, desc = 'Down (wrap-aware)' })
map('n', 'k', "v:count == 0 ? 'gk' : 'k'", { expr = true, desc = 'Up (wrap-aware)' })

-- Move lines in visual mode
map('v', 'J', ":m '>+1<CR>gv=gv", { desc = 'Move selection down' })
map('v', 'K', ":m '<-2<CR>gv=gv", { desc = 'Move selection up' })

-- Keep cursor centered on scroll/search
map('n', '<C-d>', '<C-d>zz', { desc = 'Scroll down (centered)' })
map('n', '<C-u>', '<C-u>zz', { desc = 'Scroll up (centered)' })
map('n', 'n', 'nzzzv', { desc = 'Next search (centered)' })
map('n', 'N', 'Nzzzv', { desc = 'Prev search (centered)' })

-- =============================================================================
-- Context-aware keymaps (dispatch based on project type + LSP state)
-- =============================================================================
local ctx = require('core.context')

-- Alt+O — switch header/source (universal IDE convention)
-- UE: UCM switch (module-aware), clangd: textDocument/switchSourceHeader
map('n', '<M-o>', function()
  if ctx.is_ue then
    vim.cmd('UCM switch')
  elseif ctx.has_clangd() then
    vim.cmd('ClangdSwitchSourceHeader')
  end
end, { desc = 'Switch header/source' })

-- Alt+] — references
-- LSP: vim.lsp.buf.references(), fallback: Telescope grep word
map('n', '<M-]>', function()
  if ctx.has_lsp() then
    vim.lsp.buf.references()
  else
    require('telescope.builtin').grep_string()
  end
end, { desc = 'References' })

-- Built-in keymaps NOT overridden (Neovim 0.11 defaults):
--
-- LSP (global):
--   grn    = rename symbol
--   gra    = code action (n, v)
--   grr    = references
--   gri    = implementation
--   grt    = type definition
--   gO     = document symbols
--   K      = hover documentation
--   <C-s>  = signature help (insert mode)
--
-- LSP (buffer-local on LspAttach, set automatically):
--   CTRL-] = go to definition (via tagfunc)
--   gq     = format selection (via formatexpr)
--
-- Diagnostics (global):
--   [d/]d  = prev/next diagnostic
--   [D/]D  = first/last diagnostic
--   <C-W>d = show diagnostic float
--
-- Commenting (built-in since 0.10):
--   gcc    = toggle comment (line)
--   gc     = toggle comment (visual)
--
-- Navigation (vim-unimpaired style):
--   [b/]b  = prev/next buffer
--   [q/]q  = prev/next quickfix
--   [l/]l  = prev/next loclist
--   [<Space>/]<Space> = add blank line above/below
