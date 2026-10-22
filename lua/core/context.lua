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

-- Unreal projects outside Windows: plain C++ above (the UE plugin suite is Windows-only here), except
-- for clangd and its compile database, which UBT generates on every platform (ue/compiledb_unix.lua).
--   wsl_ue: WSL in a Windows project (/mnt/d/...). clangd is Windows' clangd.exe, which reads UBT's MSVC
--           database and shares the index with Windows Neovim (lsp.lua). win_root is the Windows path
--           in its real case; root keeps the spelling used here.
--   ue_unix: native Linux / macOS. platform is UBT's name for it.
-- Both: { root, uproject, name }
local function project_info(found)
  local root = vim.fs.normalize(vim.fn.fnamemodify(found, ':h'))
  return { root = root, uproject = root .. '/' .. vim.fs.basename(found), name = vim.fn.fnamemodify(found, ':t:r') }
end
local function enter(root)
  if vim.fn.getcwd() ~= root and not vim.fn.getcwd():find(root .. '/', 1, true) then
    vim.api.nvim_set_current_dir(root)
  end
end
if not on_windows then
  local function search(dir) return dir and find_uproject(dir) end
  local found = search(vim.fn.getcwd() .. '/') or search(arg_dir and arg_dir .. '/')
  local in_wsl_mount = found and vim.env.WSL_DISTRO_NAME and found:match('^/mnt/%a/')
  if found and not in_wsl_mount then
    M.ue_unix = project_info(found)
    M.ue_unix.platform = vim.fn.has('mac') == 1 and 'Mac' or 'Linux'
    enter(M.ue_unix.root)
  end
  if in_wsl_mount then
    local info = project_info(found)
    local root = info.root
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
      info.win_root = real:sub(6, 6):upper() .. ':' .. real:sub(7)
      M.wsl_ue = info
      enter(root)
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
