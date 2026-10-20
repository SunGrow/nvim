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

local uproject = find_uproject(vim.fn.getcwd())
local arg_path, arg_dir, arg_is_uproject = first_arg()

if not uproject and arg_dir then
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

--- Check if the current buffer has an attached LSP client
function M.has_lsp(bufnr)
  return #vim.lsp.get_clients({ bufnr = bufnr or 0 }) > 0
end

--- Check if clangd specifically is attached
function M.has_clangd(bufnr)
  return #vim.lsp.get_clients({ bufnr = bufnr or 0, name = 'clangd' }) > 0
end

return M
