-- .clangd of a Windows Unreal project, the same from Windows Neovim (lang-ue.lua) and from WSL Neovim
-- (ue/uht_shadow.lua setup): both run Windows' clangd.exe on UBT's compile database. Written before
-- clangd starts, so it never has to restart for it (a restart lost a clangd started without a file:
-- Find Class in an empty Neovim).
local M = {}

-- UHT .gen.cpp and other build outputs, also in plugins (Plugins/X/Intermediate/...): each costs a full
-- UnrealEd parse in the background index (~45 s CPU), fails to compile, and only adds Z_Construct_*
-- noise to symbol search. Opened files still work. PathMatch must match the whole path relative to
-- the project.
M.SKIP_INTERMEDIATE = "'(.*/)?Intermediate/.*'"

--- The file's text (paths as clangd.exe sees them).
local function text()
  return table.concat({
    'CompileFlags:',
    -- shadow *.generated.h first: GENERATED_BODY() stays valid when lines move before the next build
    -- (lua/ue/uht_shadow.lua)
    '  Add: [-D__INTELLISENSE__, ' .. require('ue.uht_shadow').clangd_flag() .. ', -Wno-everything]',
    -- -resource-dir: UBT points it at Visual Studio's clang 19 headers. With those, clangd 20's
    -- background index records every parameter whose type is a template with a default argument
    -- (TArray, TMap, TSet, TSharedPtr, std::vector...) as `int`, so usages, overrides and callers of
    -- such functions are lost. clangd's own headers are used instead.
    '  Remove: [/Yu*, /Yc*, /Fp*, -include-pch, -resource-dir]',
    '',
    'Diagnostics:',
    '  Suppress: [pp_file_not_found, drv_unknown_argument, unknown_argument]',
    -- never "unused", as in Rider (ReSharper C++ checks IsCoreMinimalFileInclude /
    -- IsHeaderToolGeneratedFileInclude): CoreMinimal.h only includes other headers, so clangd saw no
    -- symbol come from it directly (lua/ue/uht_shadow.lua IGNORE_HEADERS)
    '  Includes:',
    '    IgnoreHeader: ' .. require('ue.uht_shadow').IGNORE_HEADERS,
    '  ClangTidy:',
    "    Remove: ['*']",
    '',
    'InlayHints:',
    '  Enabled: Yes',
    '  ParameterNames: Yes',
    '  DeducedTypes: Yes',
    '',
    '---',
    'If:',
    '  PathMatch: ' .. M.SKIP_INTERMEDIATE,
    'Index:',
    '  Background: Skip',
    '',
  }, '\n') .. require('ue.clangd_preamble').CLANGD_FRAGMENT
end

--- Write `root`/.clangd when missing, or when this config wrote it (-D__INTELLISENSE__) and it differs.
--- `root`: the project root as this Neovim reads it. True if written.
function M.ensure(root)
  local path = root .. '/.clangd'
  local new = text()
  local f = io.open(path, 'rb')
  local old = f and f:read('*a')
  if f then f:close() end
  if old and (not old:find('-D__INTELLISENSE__', 1, true) or old:gsub('\r', '') == new) then return false end
  f = io.open(path, 'wb')
  if not f then return false end
  f:write(new)
  f:close()
  vim.schedule(function() vim.notify('Updated .clangd in ' .. root, vim.log.levels.INFO, { title = 'clangd' }) end)
  return true
end

--- An index built with UBT's -resource-dir has the wrong symbol for every function taking a
--- TArray/TMap/... (see above), and clangd never re-indexes for changed flags: rebuild it once. Called
--- before clangd starts; with clangd already running (a hot reload) only ask for a restart.
function M.rebuild_index_once(root)
  local cache = root .. '/.cache/clangd'
  local marker = cache .. '/nvim-index-v2' -- written once the index is built with the current flags
  if vim.uv.fs_stat(marker) then return end
  local index = cache .. '/index'
  if vim.uv.fs_stat(index) and #vim.lsp.get_clients({ name = 'clangd' }) > 0 then
    vim.schedule(function()
      vim.notify('clangd index needs a rebuild (wrong symbols for TArray/TMap parameters): restart Neovim',
        vim.log.levels.WARN, { title = 'clangd' })
    end)
    return
  end
  if vim.uv.fs_stat(index) then
    local old = index .. '.old-' .. os.time()
    if not vim.uv.fs_rename(index, old) then return end
    if vim.fn.has('win32') == 1 then
      vim.system({ 'cmd.exe', '/c', 'rmdir', '/s', '/q', (old:gsub('/', '\\')) })
    else
      vim.system({ 'rm', '-rf', old })
    end
    vim.schedule(function() -- after startup: fidget shows it instead of a hit-enter prompt
      vim.notify('Rebuilding the clangd index (the old one had wrong symbols for TArray/TMap parameters); '
        .. 'find usages fills in as it progresses', vim.log.levels.INFO, { title = 'clangd' })
    end)
  end
  vim.fn.mkdir(cache, 'p')
  vim.fn.writefile({ 'clangd background index built without UBT -resource-dir' }, marker)
  -- more clangd threads until it is built (Windows Neovim; lua/ue/clangd_index.lua)
  if require('core.context').is_ue then require('ue.clangd_index').mark_rebuilding() end
end

return M
