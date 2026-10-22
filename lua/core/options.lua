-- =============================================================================
-- Editor options
-- =============================================================================

-- Line numbers
vim.opt.number = true
vim.opt.relativenumber = true
-- Signs, then the numbers right-aligned in one column: with 'relativenumber' Neovim puts the current
-- line's number at the left edge, out of line with the rest. Wrapped continuation lines stay blank.
vim.opt.statuscolumn = "%s%=%{v:virtnum > 0 || !(&nu || &rnu) ? '' : (&rnu && v:relnum ? v:relnum : v:lnum) .. ' '}"
-- netrw (Space e) without its six-line banner
vim.g.netrw_banner = 0

-- Mouse
vim.opt.mouse = 'a'

-- Don't show mode in cmdline (lualine handles it)
vim.opt.showmode = false

-- System clipboard
vim.opt.clipboard = 'unnamedplus'

-- Indentation
vim.opt.breakindent = true
vim.opt.expandtab = true
vim.opt.shiftwidth = 2
vim.opt.tabstop = 2
vim.opt.softtabstop = 2

-- Persistent undo
vim.opt.undofile = true

-- Search
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.inccommand = 'split'

-- UI
vim.opt.signcolumn = 'yes'
vim.opt.cursorline = true
vim.opt.scrolloff = 4
vim.opt.termguicolors = true
vim.opt.list = true
vim.opt.listchars = { tab = '» ', trail = '·', nbsp = '␣' }

-- Splits
vim.opt.splitright = true
vim.opt.splitbelow = true

-- Timing
vim.opt.updatetime = 250
vim.opt.timeoutlen = 900

-- Completion
vim.opt.completeopt = 'menu,menuone,noinsert,fuzzy'

-- Folding (treesitter-based)
vim.opt.foldmethod = 'expr'
vim.opt.foldexpr = 'v:lua.vim.treesitter.foldexpr()'
vim.opt.foldlevel = 99
vim.opt.foldenable = true
