-- Neovim process RAM (MB) — updated every 2s via timer
local ram_mb = 0

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
      -- Refresh statusline on LSP progress (clangd indexing %)
      vim.api.nvim_create_autocmd('LspProgress', {
        callback = function() vim.cmd.redrawstatus() end,
      })
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
            function()
              local status = vim.lsp.status()
              if status and status ~= '' then
                if #status > 40 then status = status:sub(1, 37) .. '...' end
                return status
              end
              return ''
            end,
            icon = '',
            color = { fg = '#9ece6a' },
          },
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
    opts = {
      delay = 0,
      spec = {
        { '<leader>f', group = 'Find' },
        { '<leader>g', group = 'Git' },
        { '<leader>l', group = 'LSP' },
        { '<leader>c', group = 'Code' },
        { '<leader>u', group = 'UI' },
        { '<leader>d', group = 'Debug' },
        { '<leader>U', group = 'Unreal' },
      },
    },
  },
}
