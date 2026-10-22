-- Avoid vim.fn.executable('make') at startup (~28-60 ms on Windows PATH scans):
-- if the fzf-native library is already built, a file stat is enough. `make` is only probed
-- when the library is missing (fresh install) so lazy.nvim can still build it.
local fzf_dir = vim.fn.stdpath('data') .. '/lazy/telescope-fzf-native.nvim/build/'
local fzf_built = vim.uv.fs_stat(fzf_dir .. 'libfzf.dll') ~= nil
  or vim.uv.fs_stat(fzf_dir .. 'libfzf.so') ~= nil
  or vim.uv.fs_stat(fzf_dir .. 'libfzf.dylib') ~= nil
local use_fzf = fzf_built or vim.fn.executable('make') == 1

-- UE projects search through UEP (modules, engine scopes), but UEP needs UNL's index. On a
-- project's first open UNL builds it in the background (minutes); until then UEP fails with
-- "No components in DB" and an ENTER prompt. Ask the index first and fall back to plain Telescope.
local function ue_or_plain(uep_cmd, plain)
  if not require('core.context').is_ue then return plain() end
  local ok, remote = pcall(require, 'UNL.db.remote')
  if not ok then return plain() end
  remote.get_components(vim.schedule_wrap(function(components, err)
    if not err and type(components) == 'table' and #components > 0 then
      return vim.cmd(uep_cmd)
    end
    vim.notify('UE index not ready yet: plain search', vim.log.levels.INFO, { title = 'UEP' })
    plain()
  end))
end

-- Unreal projects (Windows, WSL, Linux): Content/ folders hold the assets, binary .uasset/.umap files
-- with nothing to open or grep here. They are most of the files (Slam: 22,631 of 26,668), so listing
-- them took 4.6 s over WSL's /mnt/d, longer while clangd indexes, with source files arriving late;
-- without them 0.2 s.
local NO_CONTENT = { '-g', '!**/Content/**' }
local function ue_files()
  local ctx = require('core.context')
  return ctx.is_ue or ctx.wsl_ue ~= nil or ctx.ue_unix ~= nil
end

local function find_files()
  local opts = {}
  if ue_files() and vim.fn.executable('rg') == 1 then
    opts.find_command = vim.list_extend({ 'rg', '--files', '--color', 'never' }, NO_CONTENT)
  end
  require('telescope.builtin').find_files(opts)
end

local function live_grep()
  require('telescope.builtin').live_grep(ue_files() and { additional_args = NO_CONTENT } or {})
end

return {
  'nvim-telescope/telescope.nvim',
  branch = '0.1.x',
  dependencies = {
    'nvim-lua/plenary.nvim',
    { 'nvim-tree/nvim-web-devicons' },
    {
      'nvim-telescope/telescope-fzf-native.nvim',
      build = function(plugin)
        if vim.fn.executable('make') == 1 then
          vim.system({ 'make' }, { cwd = plugin.dir }):wait()
        end
      end,
      cond = use_fzf,
    },
  },
  keys = {
    { '<leader>ff', function()
        ue_or_plain('UEP files', find_files)
      end, desc = 'Find files' },
    { '<leader>fg', function()
        ue_or_plain('UEP grep', live_grep)
      end, desc = 'Live grep' },
    { '<leader>fb', function() require('telescope.builtin').buffers() end, desc = 'Buffers' },
    { '<leader>fh', function() require('telescope.builtin').help_tags() end, desc = 'Help tags' },
    { '<leader>fd', function() require('telescope.builtin').diagnostics() end, desc = 'Diagnostics' },
    { '<leader>fr', function() require('telescope.builtin').resume() end, desc = 'Resume last' },
    { '<leader>fo', function() require('telescope.builtin').oldfiles() end, desc = 'Recent files' },
    { '<leader>fw', function()
        require('telescope.builtin').grep_string(ue_files() and { additional_args = NO_CONTENT } or {})
      end, desc = 'Grep word' },
    -- searchable list of every key binding and what it does (like Rider's Find Action)
    { '<leader>?', function()
        require('telescope.builtin').keymaps({ modes = { 'n', 'x', 'i' }, show_plug = false, prompt_title = 'Keys (type to search)' })
      end, desc = 'Help: search all keys' },
    { '<leader>fk', function()
        require('telescope.builtin').keymaps({ modes = { 'n', 'x', 'i' }, show_plug = false })
      end, desc = 'Find key binding' },
    -- Rider's Search Everywhere (double Shift): files and C/C++ symbols in one list
    { '<leader><leader>', function() require('core.search_everywhere').open() end, desc = 'Search everywhere' },
    { '<leader>fc', function() require('core.symbols').classes() end, desc = 'Find class' },
    { '<leader>fs', function() require('core.symbols').functions() end, desc = 'Find function' },
    { '<leader>fS', function() require('core.symbols').all() end, desc = 'Find symbol (any kind)' },
    { '<leader>fm', function() require('core.symbols').members() end, desc = 'Find member in this file' },
    -- Git (Rider's Commit / Log / Branches windows); the preview shows each commit's diff
    { '<leader>gc', function() require('telescope.builtin').git_status() end, desc = 'Git: Changed files (Tab stages)' },
    { '<leader>gl', function() require('telescope.builtin').git_commits() end, desc = 'Git: Log' },
    { '<leader>gf', function() require('telescope.builtin').git_bcommits() end, desc = 'Git: History of this file' },
    { '<leader>gB', function() require('telescope.builtin').git_branches() end, desc = 'Git: Branches (Enter checks out)' },
  },
  config = function()
    local telescope = require('telescope')
    telescope.setup({
      defaults = {
        preview = {
          -- Prevent previewer crashes from invalid third-party Treesitter queries.
          treesitter = false,
        },
        mappings = {
          i = {
            ['<C-u>'] = false,
            ['<C-d>'] = false,
          },
        },
      },
    })
    pcall(telescope.load_extension, 'fzf')
  end,
}
