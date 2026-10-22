-- Neovim process RAM (MB) — updated every 2s via timer
local ram_mb = 0

-- UE project name (evaluated once at startup via core.context, zero cost outside UE projects); also in
-- WSL / Linux / macOS, where the UNL status and run configurations (Windows plugin suite) are absent
local ctx = require('core.context')
local ue_project_name = ctx.ue_project_name or (ctx.wsl_ue or ctx.ue_unix or {}).name or ''
local ue_tools = ctx.is_ue

--- The statusline drops its least needed items as the terminal narrows instead of cutting the line at
--- its start (Neovim's truncation hid the file name behind "<ngd, ue_ls" at 160 columns).
local function wide(cols) return function() return vim.o.columns >= cols end end

--- The window you work in: a floating window (picker, key sheet, hover) counts as the one under it.
local function work_win()
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(win).relative == '' then return win end
  local prev = vim.fn.win_getid(vim.fn.winnr('#'))
  if prev ~= 0 and vim.api.nvim_win_get_config(prev).relative == '' then return prev end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(w).relative == '' then return w end
  end
  return win
end

--- File of that window, relative to the working directory; directories shortened when it is long.
local function file_name()
  local buf = vim.api.nvim_win_get_buf(work_win())
  local name = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype ~= '' or name == '' then
    local ft = vim.bo[buf].filetype
    return name ~= '' and vim.fn.fnamemodify(name, ':t') or (ft ~= '' and ft or '[No Name]')
  end
  local path = vim.fn.fnamemodify(name, ':~:.')
  local room = math.max(24, vim.o.columns - 110)
  if vim.fn.strdisplaywidth(path) > room then path = vim.fn.pathshorten(path, 3) end
  if vim.fn.strdisplaywidth(path) > room then path = vim.fn.fnamemodify(name, ':t') end
  local flags = (vim.bo[buf].modified and ' ●' or '') .. ((vim.bo[buf].readonly or not vim.bo[buf].modifiable) and ' 󰌾' or '')
  return path .. flags
end

return {
  -- Status line
  {
    'nvim-lualine/lualine.nvim',
    dependencies = { 'nvim-tree/nvim-web-devicons' },
    event = 'VeryLazy',
    init = function()
      -- Start RAM monitor timer (lightweight, uses libuv)
      local timer = vim.uv.new_timer()
      if timer then
        timer:start(0, 2000, vim.schedule_wrap(function()
          local ok, rss = pcall(vim.uv.resident_set_memory)
          if ok then ram_mb = math.floor(rss / 1024 / 1024) end
        end))
      end
      -- NOTE: LSP progress display is handled by fidget.nvim, not the statusline.
    end,
    -- left: what you edit (file, its git and error state, clangd's progress on it); right: the project
    -- and its run configuration, then help and the cursor position
    opts = {
      options = {
        globalstatus = true,
      },
      sections = {
        lualine_a = { 'mode' },
        lualine_b = { { 'branch', cond = wide(110) }, 'diff' },
        lualine_c = {
          { file_name },
          'diagnostics',
          {
            -- clangd still parsing this file (no semantic colors / navigation yet): "⠋ building preamble";
            -- with no file: "⠋ compile db", "⠋ clangd loading index" (lua/core/clangd.lua)
            function() return require('core.clangd').text() end,
            color = { fg = '#e0af68' },
            cond = function()
              return package.loaded['core.clangd'] ~= nil
                or (package.loaded['core.compiledb'] ~= nil and require('core.compiledb').busy())
                or (package.loaded['ue.compiledb_unix'] ~= nil and require('ue.compiledb_unix').busy())
            end,
          },
          {
            -- clangd's background index while it runs: "󰒓 index 12% · 14 threads"; click for details
            function() return require('core.clangd').index_text() end,
            color = { fg = '#7dcfff' },
            cond = function() return package.loaded['core.clangd'] ~= nil and vim.o.columns >= 130 end,
            on_click = function() require('core.clangd').index_details() end,
          },
        },
        lualine_x = {
          {
            function() return ue_project_name end,
            icon = '󰿅',
            color = { fg = '#9ece6a' },
            cond = function() return ue_project_name ~= '' and vim.o.columns >= 120 end,
          },
          {
            -- UE index / server activity: "UE ⠋ indexing 42%", "UE ✓" when ready (lua/ue/status.lua)
            function() return require('ue.status').text() end,
            color = function() return require('ue.status').color() end,
            cond = function() return ue_tools end,
            on_click = function() vim.cmd('UNL status') end,
          },
          {
            -- selected run configuration, like Rider's toolbar dropdown; click to choose another
            -- (also WSL / Linux / macOS: lua/ue/run.lua)
            function() return require('ue.run').status() end,
            icon = '▶',
            color = { fg = '#e0af68' },
            cond = function() return ue_project_name ~= '' end,
            on_click = function() require('ue.run').pick() end,
          },
          {
            -- where to start when you do not know what to press (lua/core/keyhelp.lua)
            function() return 'F1 keys' end,
            icon = '󰌌',
            color = { fg = '#7aa2f7' },
            cond = wide(100),
            on_click = function() require('core.keyhelp').show() end,
          },
          {
            function() return ram_mb .. ' MB' end,
            icon = '',
            color = { fg = '#e0af68' },
            cond = wide(140),
          },
          -- only when it is not the usual UTF-8 / Unix
          { 'encoding', cond = function() return vim.bo.fileencoding ~= '' and vim.bo.fileencoding ~= 'utf-8' end },
          { 'fileformat', cond = function() return vim.bo.fileformat ~= 'unix' and vim.bo.fileformat ~= 'dos' end },
          { 'filetype', cond = wide(150) },
        },
        lualine_y = {},
        lualine_z = { 'location' },
      },
    },
  },

  -- LSP progress spinner in top-right corner
  -- and notifications: vim.notify goes to fidget's corner window instead of the command line, where a
  -- message wider than the screen (or several lines) stops everything at "Press ENTER".
  {
    'j-hui/fidget.nvim',
    lazy = false, -- before the first notification
    keys = {
      { '<leader>un', function() require('fidget.notification').show_history() end, desc = 'Notification history' },
    },
    opts = {
      progress = {
        display = {
          done_ttl = 3,
          progress_icon = { pattern = 'dots' },
        },
        -- clangd's background index runs for minutes to hours: the statusline shows it instead
        ignore = {
          function(msg) return msg.lsp_client and msg.lsp_client.name == 'clangd' and msg.token == 'backgroundIndexProgress' end,
        },
      },
      notification = {
        window = { winblend = 0 },
      },
    },
    config = function(_, opts)
      local fidget = require('fidget')
      fidget.setup(opts)
      -- vim.notify's `title` (used across this config) becomes fidget's heading
      vim.notify = function(msg, level, o)
        if o and o.title and not o.annote then o = vim.tbl_extend('keep', { annote = o.title }, o) end
        return fidget.notify(msg, level, o)
      end
    end,
  },

  -- Keymap discoverability
  {
    'folke/which-key.nvim',
    event = 'VimEnter',
    dependencies = { 'nvim-tree/nvim-web-devicons' },
    opts = {
      delay = 0,
      icons = {
        breadcrumb = '»',
        separator = '→',
        group = '+',
        ellipsis = '…',
        -- no icon column: it repeated the key as a letter ("b  B +Build") and fell back to emoji the
        -- terminal font lacks; the descriptions say what an entry does
        mappings = false,
        colors = false,
        -- Force readable footer hints for which-key actions (close/back).
        keys = {
          Space = 'SPC ',
          Tab = 'Tab ',
          CR = 'Enter ',
          Up = 'Up ',
          Down = 'Down ',
          Left = 'Left ',
          Right = 'Right ',
          Esc = 'Esc ',
          BS = 'BS ',
        },
      },
      spec = {
        { '<leader>f', group = 'Find' },
        { '<leader>g', group = 'Git' },
        { '<leader>l', group = 'LSP' },
        { '<leader>c', group = 'Code' },
        { '<leader>b', group = 'Build' },
        { '<leader>u', group = 'UI' },
        { '<leader>d', group = 'Debug' },
        { '<leader>U', group = 'Unreal' },
      },
    },
  },
}
