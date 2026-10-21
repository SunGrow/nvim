-- Treesitter: highlighting and indentation from parsers.
--
-- nvim-treesitter has two branches with different APIs: `master` (archived, supports Neovim 0.11:
-- nvim-treesitter.configs with ensure_installed/highlight) and `main` (the rewrite, needed by Neovim
-- 0.12: require('nvim-treesitter').install() plus vim.treesitter.start per buffer). Windows runs 0.11,
-- the WSL Ubuntu has 0.12-dev; the branch follows the running Neovim.
local parsers = {
  'c',
  'cpp',
  'hlsl',
  'lua',
  'vim',
  'vimdoc',
  'query',
  'markdown',
  'markdown_inline',
  'json',
  'yaml',
  'toml',
}

local main_branch = vim.fn.has('nvim-0.12') == 1

--- `main` compiles parsers with the tree-sitter CLI and a C compiler; without them installing fails
--- on every start.
local function has_treesitter_toolchain()
  if vim.fn.executable('tree-sitter') ~= 1 then
    return false
  end
  for _, compiler in ipairs({ 'cc', 'gcc', 'clang' }) do
    if vim.fn.executable(compiler) == 1 then
      return true
    end
  end
  return false
end

if main_branch then
  return {
    'nvim-treesitter/nvim-treesitter',
    branch = 'main',
    lazy = false, -- main does not support lazy-loading
    build = function()
      if has_treesitter_toolchain() then
        vim.cmd('TSUpdate')
      end
    end,
    config = function()
      local ts = require('nvim-treesitter')
      if has_treesitter_toolchain() then
        ts.install(parsers) -- only what is missing; asynchronous
      end
      vim.api.nvim_create_autocmd('FileType', {
        group = vim.api.nvim_create_augroup('nvim_treesitter_setup', { clear = true }),
        -- markdown_inline is not a filetype: markdown injects it
        pattern = vim.tbl_filter(function(p) return p ~= 'markdown_inline' end, parsers),
        callback = function(args)
          local ok = pcall(vim.treesitter.start, args.buf)
          if ok then
            vim.bo[args.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
          end
        end,
      })
    end,
  }
end

return {
  'nvim-treesitter/nvim-treesitter',
  branch = 'master',
  build = ':TSUpdate',
  event = { 'BufReadPre', 'BufNewFile' },
  config = function()
    require('nvim-treesitter.configs').setup({
      ensure_installed = parsers,
      auto_install = true,
      highlight = { enable = true },
      indent = { enable = true },
    })
  end,
}
