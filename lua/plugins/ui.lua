-- System resource monitor (updates every 2s to avoid overhead)
local sys_stats = { ram_pct = 0, cpu_pct = 0 }
local sys_timer = nil

local function start_sys_monitor()
  if sys_timer then return end
  sys_timer = vim.uv.new_timer()
  -- RAM: use vim.uv.resident_set_memory for Neovim's own usage
  -- CPU: track via uv.getrusage delta
  local prev_usage = vim.uv.getrusage()
  local prev_time = vim.uv.hrtime()
  sys_timer:start(0, 2000, vim.schedule_wrap(function()
    -- RAM (Neovim process RSS in MB)
    local ok_mem, rss = pcall(vim.uv.resident_set_memory)
    if ok_mem then
      sys_stats.ram_pct = math.floor(rss / 1024 / 1024)
    end
    -- CPU (Neovim process usage over interval)
    local ok_cpu, curr_usage = pcall(vim.uv.getrusage)
    local curr_time = vim.uv.hrtime()
    if ok_cpu and prev_usage then
      local user_delta = (curr_usage.utime.sec - prev_usage.utime.sec)
        + (curr_usage.utime.usec - prev_usage.utime.usec) / 1e6
      local sys_delta = (curr_usage.stime.sec - prev_usage.stime.sec)
        + (curr_usage.stime.usec - prev_usage.stime.usec) / 1e6
      local wall_delta = (curr_time - prev_time) / 1e9
      if wall_delta > 0 then
        sys_stats.cpu_pct = math.floor((user_delta + sys_delta) / wall_delta * 100)
      end
      prev_usage = curr_usage
      prev_time = curr_time
    end
  end))
end

local function ram_component()
  return string.format(' %dMB', sys_stats.ram_pct)
end

local function cpu_component()
  return string.format(' %d%%', sys_stats.cpu_pct)
end

local function lsp_status()
  local clients = vim.lsp.get_clients({ bufnr = 0 })
  if #clients == 0 then return '' end
  local names = {}
  for _, c in ipairs(clients) do
    names[#names + 1] = c.name
  end
  return ' ' .. table.concat(names, ', ')
end

local function lsp_progress()
  -- Show active LSP progress (clangd indexing, etc.)
  local progress = vim.lsp.status()
  if progress and progress ~= '' then
    -- Truncate long messages
    if #progress > 40 then
      progress = progress:sub(1, 37) .. '...'
    end
    return ' ' .. progress
  end
  return ''
end

return {
  -- Status line
  {
    'nvim-lualine/lualine.nvim',
    dependencies = { 'nvim-tree/nvim-web-devicons' },
    event = 'VeryLazy',
    config = function()
      start_sys_monitor()
      require('lualine').setup({
        options = {
          globalstatus = true,
          section_separators = { left = '', right = '' },
          component_separators = { left = '', right = '' },
        },
        sections = {
          lualine_a = { 'mode' },
          lualine_b = { 'branch', 'diff', 'diagnostics' },
          lualine_c = {
            { 'filename', path = 1 },
            { lsp_status, color = { fg = '#7aa2f7' } },
            { lsp_progress, color = { fg = '#9ece6a' } },
          },
          lualine_x = {
            { ram_component, color = { fg = '#e0af68' } },
            { cpu_component, color = { fg = '#f7768e' } },
            'encoding',
            'fileformat',
            'filetype',
          },
          lualine_y = { 'progress' },
          lualine_z = { 'location' },
        },
      })
      -- Refresh lualine when LSP progress updates
      vim.api.nvim_create_autocmd('LspProgress', {
        callback = function() vim.cmd.redrawstatus() end,
      })
    end,
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
