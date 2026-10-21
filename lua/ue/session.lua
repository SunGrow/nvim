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

-- Sessions saved before UNL's paths were fixed (lang-ue.lua patch_unl_paths) hold buffers named
-- `D:///Development/...`: restored as a second buffer of the file, with an LSP URI that matches
-- neither compile_commands.json nor clangd's index. Rewritten to `D:/...` before sourcing.
local function fix_paths(file)
  local f = io.open(file, 'rb')
  if not f then return end
  local text = f:read('*a')
  f:close()
  local fixed, n = text:gsub('(%f[%w][A-Za-z]:)//+', '%1/')
  if n == 0 then return end
  f = io.open(file, 'wb')
  if f then
    f:write(fixed)
    f:close()
  end
end
M._fix_paths = fix_paths

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
        pcall(fix_paths, session_file())
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
