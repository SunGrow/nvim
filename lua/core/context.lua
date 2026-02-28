-- Project context detection — evaluated once at startup, cached module-level.
-- Replaces duplicate vim.fs.find('.uproject') calls across lang-ue, lang-cpp, lsp, ui.
local M = {}

-- .uproject detection (upward search from cwd)
local uproject_files = vim.fs.find(function(name)
  return name:match('%.uproject$') ~= nil
end, { upward = true, type = 'file', path = vim.fn.getcwd(), limit = 1 })

M.is_ue = #uproject_files > 0
M.ue_project_root = M.is_ue and vim.fn.fnamemodify(uproject_files[1], ':h') or nil
M.ue_project_name = M.is_ue and vim.fn.fnamemodify(uproject_files[1], ':t:r') or nil

--- Check if the current buffer has an attached LSP client
function M.has_lsp(bufnr)
  return #vim.lsp.get_clients({ bufnr = bufnr or 0 }) > 0
end

--- Check if clangd specifically is attached
function M.has_clangd(bufnr)
  return #vim.lsp.get_clients({ bufnr = bufnr or 0, name = 'clangd' }) > 0
end

return M
