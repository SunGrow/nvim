-- Neovim process RAM (MB) — updated every 2s via timer
local ram_mb = 0

-- UE project name (evaluated once at startup via core.context, zero cost outside UE projects)
local ue_project_name = require('core.context').ue_project_name or ''

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
    opts = {
      options = {
        globalstatus = true,
      },
      sections = {
        lualine_a = { 'mode' },
        lualine_b = { 'branch', 'diff', 'diagnostics' },
        lualine_c = {
          { 'filename', path = 1 },
          {
            function()
              local clients = vim.lsp.get_clients({ bufnr = 0 })
              if #clients == 0 then return '' end
              local names = {}
              for _, c in ipairs(clients) do
                names[#names + 1] = c.name
              end
              return table.concat(names, ', ')
            end,
            icon = '',
            color = { fg = '#7aa2f7' },
          },
          {
            -- clangd still parsing this file (no semantic colors / navigation yet): "⠋ building preamble"
            function() return require('core.clangd').text() end,
            color = { fg = '#e0af68' },
            cond = function() return package.loaded['core.clangd'] ~= nil end,
          },
          {
            function() return ue_project_name end,
            icon = '󰿅',
            color = { fg = '#9ece6a' },
            cond = function() return ue_project_name ~= '' end,
          },
          {
            -- UE index / server activity: "UE ⠋ indexing 42%", "UE ✓" when ready (lua/ue/status.lua)
            function() return require('ue.status').text() end,
            color = function() return require('ue.status').color() end,
            cond = function() return ue_project_name ~= '' end,
            on_click = function() vim.cmd('UNL status') end,
          },
          {
            -- selected run configuration, like Rider's toolbar dropdown; click to choose another
            function() return require('ue.run').status() end,
            icon = '▶',
            color = { fg = '#e0af68' },
            cond = function() return ue_project_name ~= '' end,
            on_click = function() require('ue.run').pick() end,
          },
          -- NOTE: LSP progress is handled by fidget.nvim (top-right spinner).
          -- fidget consumes the LSP progress ring buffer, so vim.lsp.status()
          -- returns empty when fidget is active. Don't duplicate it here.
        },
        lualine_x = {
          {
            function() return ram_mb .. 'MB' end,
            icon = '',
            color = { fg = '#e0af68' },
          },
          'encoding',
          'filetype',
        },
        lualine_y = { 'progress' },
        lualine_z = { 'location' },
      },
    },
  },

  -- LSP progress spinner in top-right corner
  {
    'j-hui/fidget.nvim',
    event = 'LspAttach',
    opts = {
      progress = {
        display = {
          done_ttl = 3,
          progress_icon = { pattern = 'dots' },
        },
      },
      notification = {
        window = { winblend = 0 },
      },
    },
  },

  -- Keymap discoverability
  {
    'folke/which-key.nvim',
    event = 'VimEnter',
    dependencies = { 'nvim-tree/nvim-web-devicons' },
    opts = {
      delay = 0,
      icons = {
        breadcrumb = '> ',
        separator = '->',
        group = '+',
        ellipsis = '...',
        mappings = true,
        -- Keep icon coloring predictable across themes.
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
        -- Font-safe fallback icon rules so icons still render without Nerd Font glyphs.
        rules = {
          { pattern = 'find', icon = '⌕ ' },
          { pattern = 'grep', icon = '⌕ ' },
          { pattern = 'build', icon = '⚙ ' },
          { pattern = 'debug', icon = '🐞 ' },
          { pattern = 'class', icon = 'C ' },
          { pattern = 'struct', icon = 'S ' },
          { pattern = 'enum', icon = 'E ' },
          { pattern = 'include', icon = 'I ' },
          { pattern = 'unreal', icon = 'U ' },
        },
      },
      spec = {
        { '<leader>f', group = 'Find', icon = '⌕ ' },
        { '<leader>g', group = 'Git', icon = 'G ' },
        { '<leader>l', group = 'LSP', icon = 'L ' },
        { '<leader>c', group = 'Code', icon = 'C ' },
        { '<leader>b', group = 'Build', icon = 'B ' },
        { '<leader>u', group = 'UI', icon = 'UI' },
        { '<leader>d', group = 'Debug', icon = '🐞 ' },
        { '<leader>U', group = 'Unreal', icon = 'U ' },
      },
    },
  },
}
