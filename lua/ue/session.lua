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
    callback = function()
      if not has_ui() or vim.fn.argc() > 0 or not vim.uv.fs_stat(session_file()) then return end
      -- After every VimEnter handler: the session wipes the empty start buffer, and UNL's own
      -- VimEnter handler (plugin/UNL.lua) still indexes it ("Invalid buffer id: 1" + ENTER prompt).
      -- Outside the autocmd, BufRead/FileType/LSP autocmds run normally for the restored buffers.
      vim.schedule(function()
        pcall(vim.cmd, 'silent! source ' .. vim.fn.fnameescape(session_file()))
      end)
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
