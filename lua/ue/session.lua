-- Reopen the project's last files and window layout when Neovim starts in a UE project without
-- file arguments, like an IDE reopening its tabs. Built-in :mksession, one file per project;
-- headless runs neither restore nor save.
local ctx = require('core.context')

local M = {}

local function session_file()
  return vim.fn.stdpath('state') .. '/sessions/' .. ctx.ue_project_name .. '.vim'
end

local function has_ui()
  return #vim.api.nvim_list_uis() > 0
end

local function save()
  -- Plugin and tool windows (dap-ui, quickfix, help, terminals) do not belong in the session.
  pcall(function() require('dapui').close() end)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype ~= '' and #vim.api.nvim_list_wins() > 1 then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  vim.fn.mkdir(vim.fn.fnamemodify(session_file(), ':h'), 'p')
  local saved = vim.o.sessionoptions
  vim.o.sessionoptions = 'buffers,curdir,folds,tabpages,winsize'
  pcall(vim.cmd, 'mksession! ' .. vim.fn.fnameescape(session_file()))
  vim.o.sessionoptions = saved
end

function M.setup()
  local group = vim.api.nvim_create_augroup('UeSession', { clear = true })
  vim.api.nvim_create_autocmd('VimEnter', {
    group = group,
    once = true,
    nested = true, -- let BufRead/FileType/LSP autocmds run for the restored buffers
    callback = function()
      if not has_ui() or vim.fn.argc() > 0 or not vim.uv.fs_stat(session_file()) then return end
      pcall(vim.cmd, 'silent! source ' .. vim.fn.fnameescape(session_file()))
    end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      if has_ui() and vim.v.dying == 0 then save() end
    end,
  })
end

return M
