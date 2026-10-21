-- Project context detection — evaluated once at startup, cached module-level.
-- Replaces duplicate vim.fs.find('.uproject') calls across lang-ue, lang-cpp, lsp, ui.
local M = {}

-- .uproject detection (upward search). Start points, in order:
--   1. cwd
--   2. the first file argument (`nvim path/to/Source/x.cpp`, a directory, or a `.uproject` itself)
local function is_uproject(name)
  return name:match('%.uproject$') ~= nil
end

local function find_uproject(dir)
  return vim.fs.find(is_uproject, { upward = true, type = 'file', path = dir, limit = 1 })[1]
end

local function first_arg()
  local arg = vim.fn.argv(0)
  if type(arg) ~= 'string' or arg == '' then
    return nil
  end
  local abs = vim.fn.fnamemodify(arg, ':p')
  local stat = vim.uv.fs_stat(abs)
  if stat and stat.type == 'directory' then
    return abs, abs, false
  end
  -- Non-existent files (new buffers) still resolve via their directory.
  return abs, vim.fn.fnamemodify(abs, ':h'), is_uproject(abs) and stat ~= nil
end

-- The Unreal tooling here is Windows-only (UBT and engine paths, Win64 binaries, the WinDbg-based
-- debugger, an MSVC compile database). Elsewhere (WSL opening /mnt/d/...) a UE project is plain C++.
local on_windows = vim.fn.has('win32') == 1
local uproject = on_windows and find_uproject(vim.fn.getcwd()) or nil
local arg_path, arg_dir, arg_is_uproject = first_arg()

if on_windows and not uproject and arg_dir then
  if arg_is_uproject then
    uproject = arg_path
  elseif vim.uv.fs_stat(arg_dir) then
    uproject = find_uproject(arg_dir)
  end
  -- Project found via the argument (not cwd): move to the project root so
  -- cwd-based UE tooling (UEP/UNL/UBT/UEA) sees the project, like opening it in an IDE.
  if uproject then
    vim.api.nvim_set_current_dir(vim.fn.fnamemodify(uproject, ':h'))
  end
end

M.is_ue = uproject ~= nil
M.ue_project_root = uproject and vim.fs.normalize(vim.fn.fnamemodify(uproject, ':h')) or nil
M.ue_project_name = uproject and vim.fn.fnamemodify(uproject, ':t:r') or nil

-- WSL in a Windows UE project (/mnt/d/...): plain C++ above, except that clangd is Windows' clangd.exe,
-- which reads UBT's MSVC compile database and shares the index with Windows Neovim (lsp.lua).
-- wsl_ue = { root = the project root as spelled here, win_root = its Windows path in its real case }
if not on_windows and vim.env.WSL_DISTRO_NAME then
  local function mnt(dir) return dir and dir:match('^/mnt/%a/') and find_uproject(dir) end
  local found = mnt(vim.fn.getcwd() .. '/') or mnt(arg_dir and arg_dir .. '/')
  if found then
    local root = vim.fs.normalize(vim.fn.fnamemodify(found, ':h'))
    -- DrvFs ignores case, so the path typed in the shell (/mnt/d/development/v2) can differ from the
    -- case clangd and the compile database use: take each name as the directory lists it
    local real, ok = root:sub(1, 6), true
    for part in root:sub(8):gmatch('[^/]+') do
      local match
      for name in vim.fs.dir(real) do
        if name:lower() == part:lower() then match = name; if name == part then break end end
      end
      if not match then ok = false; break end
      real = real .. '/' .. match
    end
    if ok then
      M.wsl_ue = { root = root, win_root = real:sub(6, 6):upper() .. ':' .. real:sub(7) }
      if vim.fn.getcwd() ~= root and not vim.fn.getcwd():find(root .. '/', 1, true) then
        vim.api.nvim_set_current_dir(root)
      end
    end
  end
end

--- Check if the current buffer has an attached LSP client
function M.has_lsp(bufnr)
  return #vim.lsp.get_clients({ bufnr = bufnr or 0 }) > 0
end

--- Check if clangd specifically is attached
function M.has_clangd(bufnr)
  return #vim.lsp.get_clients({ bufnr = bufnr or 0, name = 'clangd' }) > 0
end

return M
