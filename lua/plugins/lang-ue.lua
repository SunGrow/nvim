-- Unreal Engine 5 development support (taku25 suite)
-- Zero overhead outside UE projects: all specs use cond = is_ue_project

-- Detect UE project by searching upward for any .uproject file
-- Evaluated once at startup (lazy.nvim cond is session-level)
local is_ue_project = (function()
  local found = vim.fs.find(function(name)
    return name:match('%.uproject$') ~= nil
  end, {
    upward = true,
    type = 'file',
    path = vim.fn.getcwd(),
    limit = 1,
  })
  return #found > 0
end)()

return {
  -- UNL.nvim: Core library (required by all taku25 plugins)
  {
    'taku25/UNL.nvim',
    build = 'cargo build --release --manifest-path scanner/Cargo.toml',
    lazy = false,
    cond = is_ue_project,
    opts = {
      ui = {
        picker = { mode = 'auto', prefer = { 'telescope', 'native' } },
        progress = { enable = true, mode = 'auto' },
      },
      logging = {
        level = 'info',
        file = { enable = true },
      },
    },
  },

  -- UnrealDev.nvim: Meta-plugin providing :UDEV unified command
  {
    'taku25/UnrealDev.nvim',
    cond = is_ue_project,
    cmd = { 'UDEV' },
    dependencies = {
      'taku25/UNL.nvim',
      'taku25/UEP.nvim',
      'taku25/UBT.nvim',
      'taku25/UCM.nvim',
      'taku25/UEA.nvim',
      'taku25/ULG.nvim',
      'taku25/UDB.nvim',
    },
    opts = {},
  },

  -- UEP.nvim: Project explorer, file navigation, inheritance analysis
  {
    'taku25/UEP.nvim',
    cond = is_ue_project,
    cmd = { 'UEP' },
    dependencies = { 'taku25/UNL.nvim' },
    opts = {},
    -- stylua: ignore
    keys = {
      { '<leader>Uf', '<cmd>UEP files<CR>', desc = 'Unreal: Find files' },
      { '<leader>Ug', '<cmd>UEP grep<CR>', desc = 'Unreal: Grep project' },
      { '<leader>Uc', '<cmd>UEP classes<CR>', desc = 'Unreal: Browse classes' },
      { '<leader>Us', '<cmd>UEP structs<CR>', desc = 'Unreal: Browse structs' },
      { '<leader>Ue', '<cmd>UEP enums<CR>', desc = 'Unreal: Browse enums' },
      { '<leader>Ud', '<cmd>UEP find_derived<CR>', desc = 'Unreal: Find derived classes' },
      { '<leader>Up', '<cmd>UEP find_parents<CR>', desc = 'Unreal: Find parent classes' },
      { '<leader>Ui', '<cmd>UEP add_include<CR>', desc = 'Unreal: Add #include' },
      { '<leader>Ut', '<cmd>UEP tree<CR>', desc = 'Unreal: Project tree' },
      { '<leader>Ur', '<cmd>UEP refresh<CR>', desc = 'Unreal: Refresh project' },
    },
  },

  -- UBT.nvim: Build tool, compile_commands.json, UHT
  {
    'taku25/UBT.nvim',
    cond = is_ue_project,
    cmd = { 'UBT' },
    dependencies = { 'taku25/UNL.nvim' },
    opts = {},
    -- stylua: ignore
    keys = {
      { '<leader>Ub', '<cmd>UBT build<CR>', desc = 'Unreal: Build' },
      { '<leader>UB', '<cmd>UBT build!<CR>', desc = 'Unreal: Build (pick target)' },
      { '<leader>Uj', '<cmd>UBT gen_compile_db<CR>', desc = 'Unreal: Generate compile_commands.json' },
      { '<leader>Uh', '<cmd>UBT gen_header<CR>', desc = 'Unreal: Generate headers (UHT)' },
    },
  },

  -- UCM.nvim: Class creation, header/source switching
  {
    'taku25/UCM.nvim',
    cond = is_ue_project,
    cmd = { 'UCM' },
    dependencies = { 'taku25/UNL.nvim' },
    opts = {},
    -- stylua: ignore
    keys = {
      { '<leader>Un', '<cmd>UCM new<CR>', desc = 'Unreal: New class' },
      { '<leader>Uo', '<cmd>UCM switch<CR>', desc = 'Unreal: Switch header/source' },
    },
  },

  -- UEA.nvim: Blueprint/asset tracking, Code Lens
  {
    'taku25/UEA.nvim',
    cond = is_ue_project,
    cmd = { 'UEA' },
    dependencies = {
      'taku25/UNL.nvim',
      'taku25/UEP.nvim',
    },
    opts = {},
    -- stylua: ignore
    keys = {
      { '<leader>Ua', '<cmd>UEA find_bp_usages<CR>', desc = 'Unreal: Blueprint usages' },
      { '<leader>UA', '<cmd>UEA find_references<CR>', desc = 'Unreal: Asset references' },
    },
  },

  -- ULG.nvim: Real-time log viewer
  {
    'taku25/ULG.nvim',
    cond = is_ue_project,
    cmd = { 'ULG' },
    dependencies = { 'taku25/UNL.nvim' },
    opts = {},
    -- stylua: ignore
    keys = {
      { '<leader>Ul', '<cmd>ULG start<CR>', desc = 'Unreal: Start log viewer' },
    },
  },

  -- UDB.nvim: Debug integration (wraps nvim-dap with UE auto-config)
  {
    'taku25/UDB.nvim',
    cond = is_ue_project,
    cmd = { 'UDB' },
    dependencies = {
      'taku25/UNL.nvim',
      'mfussenegger/nvim-dap',
    },
    opts = {},
    -- stylua: ignore
    keys = {
      { '<leader>UD', '<cmd>UDB run<CR>', desc = 'Unreal: Debug (default target)' },
      { '<leader>US', '<cmd>UDB run!<CR>', desc = 'Unreal: Debug (select target)' },
    },
  },
}
