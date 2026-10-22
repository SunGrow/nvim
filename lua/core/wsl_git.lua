-- WSL: `git` started from Neovim (gitsigns, Telescope's git pickers, :terminal) runs Windows' git.exe
-- for working trees on Windows drives (bin/wsl/git says why). Before plugins load: they look git up
-- on PATH each time they run it.
local M = {}

function M.setup()
  if not vim.env.WSL_DISTRO_NAME then return end
  local dir = vim.fn.stdpath('config') .. '/bin/wsl'
  if vim.fn.executable(dir .. '/git') ~= 1 then return end
  if not (':' .. vim.env.PATH .. ':'):find(':' .. dir .. ':', 1, true) then
    vim.env.PATH = dir .. ':' .. vim.env.PATH
  end
end

return M
