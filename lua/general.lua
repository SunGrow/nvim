-- Basic settings
-- 
vim.o.encoding = "utf-8"
vim.o.backspace = "indent,eol,start" -- backspace works on every char in insert mode
vim.o.completeopt = 'menuone,noinsert,noselect'
vim.g.completion_matching_strategy_list = {'exact', 'substring', 'fuzzy'}
vim.o.history = 1000
vim.o.laststatus = 2
vim.g.mapleader = ' ' -- Set leader key
vim.o.so = 4 -- How many lines from edge before scrolling
vim.opt.termguicolors = true
vim.wo.number = true
vim.wo.relativenumber = true
vim.cmd('set clipboard+=unnamedplus')

-- Enable natural language spell check
vim.opt.spelllang = 'en_gb'
vim.opt.spell = true

-- Enable filetype plugins
vim.cmd('filetype plugin on')
vim.cmd('filetype indent on')
-- Set to auto read when a file is changed from the outside
vim.g.autoread = true
vim.cmd('au CursorHold * checktime')
vim.cmd('au FocusGained,BufEnter * checktime')

vim.cmd[[
augroup LargeFile
        let g:large_file = 10485760

        " Set options:
        "   eventignore+=FileType (no syntax highlighting etc
        "   assumes FileType always on)
        "   noswapfile (save copy of file)
        "   bufhidden=unload (save memory when other file is viewed)
        "   buftype=nowritefile (is read-only)
        "   undolevels=-1 (no undo possible)
        au BufReadPre *
                \ let f=expand("<afile>") |
                \ if getfsize(f) > g:large_file |
                        \ set eventignore+=FileType |
                        \ setlocal noswapfile bufhidden=unload buftype=nowrite undolevels=-1 |
                \ else |
                        \ set eventignore-=FileType |
                \ endif
augroup END
]]

vim.o.ignorecase = true -- Ignore case when searching
vim.o.smartcase = true -- When search for capital letter, become case sensitive
vim.o.hlsearch = true -- Highlight search results
vim.o.incsearch = true -- Makes search act like search in modern browsers
vim.g.lazyredraw = true -- Don't redraw while executing macros (good performance config)
vim.g.magic = true -- For regular expressions turn magic on
vim.g.showmatch = true -- Show matching brackets when text indicator is over them
-- No annoying sound on errors
vim.g.errorbells = false
vim.g.visualbell = false
vim.g.t_vb = ''
vim.g.tm=500
-- GUI
--vim.g.guioptions-=r
--vim.g.guioptions-=R
--vim.g.guioptions-=l
--vim.g.guioptions-=L


-- Mapping waiting time
vim.o.timeout = false
vim.o.ttimeout = true
vim.o.ttimeoutlen = 100

-- Theme
vim.g.gruvbox_contrast_dark = 'hard'
vim.o.background = 'light'
vim.cmd('colorscheme catppuccin')
vim.g.guifont = 'JetBrains Mono:h11'
vim.o.linespace = 4

-- Formating
vim.o.softtabstop = 4
vim.o.shiftwidth = 4
vim.o.tabstop = 4
vim.cmd('syntax on')
vim.o.expandtab = true;


-- Latex
vim.g.tex_flavor = 'latex'
vim.g.vimtex_view_method = 'zathura'




