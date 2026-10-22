-- =============================================================================
-- Autocommands
-- =============================================================================
local augroup = vim.api.nvim_create_augroup
local autocmd = vim.api.nvim_create_autocmd

-- Lua garbage collector: LuaJIT's default pause (200) lets the heap grow to twice what is live before a
-- cycle, and freed pages do not go back to the OS. With 110 a scripted WSL session (12 files, engine
-- headers, completion, searches) peaked at 62 MB RSS instead of 85 MB. Set after startup, where it cost
-- ~30 ms (7%) of the 0.45 s.
autocmd('VimEnter', {
  group = augroup('gc-pause', { clear = true }),
  once = true,
  callback = function()
    vim.defer_fn(function() collectgarbage('setpause', 110) end, 1000)
  end,
})

-- Highlight on yank
autocmd('TextYankPost', {
  group = augroup('highlight-yank', { clear = true }),
  callback = function()
    vim.hl.on_yank()
  end,
})

-- Resize splits when the terminal is resized (also each step of a font zoom). Debounced: a zoom sends
-- a burst of VimResized. `tabdo` would leave the last tab page current, so every tab page is
-- equalized without autocmds and the current one restored. The debugger panels (dap-ui) are fixed
-- size (winfixwidth/height), so `wincmd =` cannot share a size change between them and Neovim forces
-- it onto one panel (stack 2 rows, REPL 2 rows, never growing back); their layouts are reset to the
-- configured proportions instead (lua/core/debug_ui.lua).
local resize_timer
autocmd('VimResized', {
  group = augroup('resize-splits', { clear = true }),
  callback = function()
    resize_timer = resize_timer or vim.uv.new_timer()
    resize_timer:stop()
    resize_timer:start(40, 0, vim.schedule_wrap(function()
      local cur = vim.api.nvim_get_current_tabpage()
      for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
        vim.cmd('noautocmd ' .. vim.api.nvim_tabpage_get_number(tab) .. 'tabnext')
        vim.cmd('noautocmd wincmd =')
      end
      vim.cmd('noautocmd ' .. vim.api.nvim_tabpage_get_number(cur) .. 'tabnext')
      if package.loaded['dapui'] then pcall(require('core.debug_ui').relayout) end
    end))
  end,
})

-- Return to last edit position on file open
autocmd('BufReadPost', {
  group = augroup('last-position', { clear = true }),
  callback = function(args)
    local mark = vim.api.nvim_buf_get_mark(args.buf, '"')
    local line_count = vim.api.nvim_buf_line_count(args.buf)
    if mark[1] > 0 and mark[1] <= line_count then
      pcall(vim.api.nvim_win_set_cursor, 0, mark)
    end
  end,
})

-- Close certain filetypes with q
autocmd('FileType', {
  group = augroup('close-with-q', { clear = true }),
  pattern = { 'help', 'qf', 'checkhealth', 'netrw' },
  callback = function(event)
    vim.bo[event.buf].buflisted = false
    vim.keymap.set('n', 'q', '<cmd>close<CR>', { buffer = event.buf, silent = true })
  end,
})
