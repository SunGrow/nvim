-- Unreal Engine 5 development support (taku25 suite)
-- Zero overhead outside UE projects: all specs use cond = is_ue_project

-- Detect UE project by searching upward for any .uproject file
-- Evaluated once at startup (lazy.nvim cond is session-level)
local uproject_files = vim.fs.find(function(name)
  return name:match('%.uproject$') ~= nil
end, {
  upward = true,
  type = 'file',
  path = vim.fn.getcwd(),
  limit = 1,
})
local is_ue_project = #uproject_files > 0
local project_name = nil

-- Compatibility shim for plugins that call string:starts_with(...)
if string.starts_with == nil then
  function string.starts_with(str, prefix)
    return str:sub(1, #prefix) == prefix
  end
end

-- UNL Telescope callback picker compatibility patch.
-- Fixes dynamic picker selection crashes caused by invalid prompt buffer handling.
local function patch_unl_telescope_provider()
  local ok, provider = pcall(require, 'UNL.backend.picker.provider.telescope')
  if not ok or type(provider) ~= 'table' or provider._lazyf_patch_applied then
    return
  end

  provider._lazyf_patch_applied = true

  provider.run_callback = function(spec, source)
    local actions = require('telescope.actions')
    local action_state = require('telescope.actions.state')
    local finders = require('telescope.finders')
    local pickers = require('telescope.pickers')
    local conf = require('telescope.config').values
    local entry_display = require('telescope.pickers.entry_display')
    local devicons_ok, devicons = pcall(require, 'nvim-web-devicons')
    local use_devicons = spec.devicons_enabled ~= false and devicons_ok

    local results = {}
    local displayer
    local make_display
    if use_devicons then
      displayer = entry_display.create({ separator = ' ', items = { { width = 2 }, { remaining = true } } })
      make_display = function(entry)
        return displayer({ { entry.icon, entry.icon_hl }, entry.display_text })
      end
    end

    local entry_maker = function(entry)
      local value, display, filename, lnum, col
      if type(entry) == 'table' then
        value = entry.value or entry
        display = entry.display or entry.label or entry.name or tostring(value)
        filename = entry.filename or (type(value) == 'table' and value.filename)
        lnum = entry.lnum or entry.line or entry.row
        col = entry.col
      else
        value = entry
        display = tostring(entry)
        filename = tostring(entry)
      end

      local result = {
        value = value,
        display = display,
        ordinal = display,
        filename = filename,
        lnum = lnum and tonumber(lnum),
        col = col and tonumber(col),
      }

      if use_devicons and filename and type(filename) == 'string' then
        local extension = vim.fn.fnamemodify(filename, ':e')
        local icon, icon_hl = devicons.get_icon(filename, extension)
        result.icon = icon or (type(entry) == 'table' and entry.icon) or ''
        result.icon_hl = icon_hl or 'Normal'
        result.display_text = display
        if make_display then
          result.display = make_display
        end
      else
        result.icon = (type(entry) == 'table' and entry.icon) or ''
        result.icon_hl = 'Normal'
      end
      return result
    end

    local finder = setmetatable({ results = results, close = function() end }, {
      __call = function(_, _, cb, cb_complete)
        for _, item in ipairs(results) do
          local e = entry_maker(item)
          if e then
            cb(e)
          end
        end
        if cb_complete then
          cb_complete()
        end
      end,
    })

    local picker = pickers.new({
      prompt_title = spec.title or 'Dynamic Picker',
      finder = finder,
      sorter = conf.generic_sorter({}),
      previewer = (spec.preview_enabled ~= false) and conf.file_previewer({}) or nil,
      sorting_strategy = 'ascending',
      attach_mappings = function(bufnr)
        actions.select_default:replace(function()
          local current_picker = action_state.get_current_picker(bufnr)
          actions.close(bufnr)
          local get_value = function(entry)
            return entry and entry.value or nil
          end
          local is_multi = (spec.multiselect == 'native' or spec.multiselect == true)
          if is_multi and current_picker then
            local picked = {}
            for _, entry in ipairs(current_picker:get_multi_selection()) do
              table.insert(picked, get_value(entry))
            end
            if #picked == 0 then
              local selected = action_state.get_selected_entry()
              if selected then
                table.insert(picked, get_value(selected))
              end
            end
            if spec.on_confirm then
              vim.schedule(function()
                spec.on_confirm(picked)
              end)
            end
          else
            local selected = action_state.get_selected_entry()
            if spec.on_confirm then
              vim.schedule(function()
                spec.on_confirm(get_value(selected))
              end)
            end
          end
        end)
        return true
      end,
    })
    picker.tiebreak = function()
      return false
    end
    picker:find()

    local push = function(items)
      if not items then
        return
      end
      local to_add = (type(items) == 'table' and items[1] ~= nil) and items or { items }
      for _, it in ipairs(to_add) do
        table.insert(results, it)
      end
      vim.schedule(function()
        if picker.prompt_bufnr and vim.api.nvim_buf_is_valid(picker.prompt_bufnr) and picker._on_lines then
          picker._on_lines()
        end
      end)
    end

    if source.fn then
      source.fn(push)
    end
  end
end

-- Auto-create .clangd + set UE indentation when in a UE project
if is_ue_project then
  local project_root = vim.fn.fnamemodify(uproject_files[1], ':h')
  project_name = vim.fn.fnamemodify(uproject_files[1], ':t:r')
  local clangd_path = project_root .. '/.clangd'
  local clangd_config = table.concat({
    'CompileFlags:',
    '  Add: [-D__INTELLISENSE__, -Wno-everything]',
    '  Remove: [/Yu*, /Yc*, /Fp*, -include-pch]',
    '',
    'Diagnostics:',
    '  Suppress: [pp_file_not_found, drv_unknown_argument, unknown_argument]',
    '  ClangTidy:',
    "    Remove: ['*']",
    '',
    'InlayHints:',
    '  Enabled: Yes',
    '  ParameterNames: Yes',
    '  DeducedTypes: Yes',
    '',
  }, '\n')

  local should_write = vim.fn.filereadable(clangd_path) == 0
  if not should_write then
    local existing = table.concat(vim.fn.readfile(clangd_path), '\n')
    local managed_by_this_config = existing:find('-D__INTELLISENSE__', 1, true) ~= nil
    local strips_required_forced_includes = existing:find('/FI*', 1, true) ~= nil
      or existing:find('-include]', 1, true) ~= nil
      or existing:find('-include,', 1, true) ~= nil
    if managed_by_this_config and strips_required_forced_includes then
      should_write = true
    end
  end

  if should_write then
    vim.fn.writefile(vim.split(clangd_config, '\n'), clangd_path)
    vim.notify('Updated .clangd in ' .. project_root, vim.log.levels.INFO)
  end

  -- UE Coding Standards: tabs with width 4 for C/C++ files
  -- Acts as fallback — .editorconfig (if present) overrides via BufReadPost
  vim.api.nvim_create_autocmd('FileType', {
    group = vim.api.nvim_create_augroup('UnrealIndent', { clear = true }),
    pattern = { 'c', 'cpp' },
    callback = function()
      vim.bo.expandtab = false
      vim.bo.tabstop = 4
      vim.bo.shiftwidth = 4
      vim.bo.softtabstop = 4
    end,
  })

  -- Keep UE filetypes simple and parser-compatible (no custom parser required).
  vim.api.nvim_create_autocmd({ 'BufRead', 'BufNewFile' }, {
    group = vim.api.nvim_create_augroup('UnrealFiletype', { clear = true }),
    pattern = '*.uproject',
    callback = function()
      vim.bo.filetype = 'json'
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufRead', 'BufNewFile' }, {
    group = vim.api.nvim_create_augroup('UnrealShaderFiletype', { clear = true }),
    pattern = { '*.ush', '*.usf' },
    callback = function()
      vim.bo.filetype = 'hlsl'
    end,
  })
end

local ubt_presets = nil
if project_name ~= nil then
  -- UBT.nvim currently derives invalid target names for default presets on Windows.
  -- We pin explicit TargetName values to keep build and compile DB commands stable.
  ubt_presets = {
    { name = 'Win64DebugGame', TargetName = project_name, Platform = 'Win64', IsEditor = false, Configuration = 'DebugGame' },
    { name = 'Win64Develop', TargetName = project_name, Platform = 'Win64', IsEditor = false, Configuration = 'Development' },
    { name = 'Win64Shipping', TargetName = project_name, Platform = 'Win64', IsEditor = false, Configuration = 'Shipping' },
    { name = 'Win64DebugGameWithEditor', TargetName = project_name .. 'Editor', Platform = 'Win64', IsEditor = true, Configuration = 'DebugGame' },
    { name = 'Win64DevelopWithEditor', TargetName = project_name .. 'Editor', Platform = 'Win64', IsEditor = true, Configuration = 'Development' },
  }
end

return {
  -- Core UE runtime/index layer.
  {
    'taku25/UNL.nvim',
    build = 'cargo build --release --manifest-path scanner/Cargo.toml',
    lazy = false,
    cond = is_ue_project,
    opts = {
      ui = {
        picker = { mode = 'telescope', prefer = { 'telescope', 'native' } },
        grep_picker = { mode = 'telescope', prefer = { 'telescope', 'native' } },
        progress = { enable = true, mode = 'auto' },
      },
      logging = {
        level = 'info',
        file = { enable = true },
      },
    },
    config = function(_, opts)
      require('UNL').setup(opts)
      patch_unl_telescope_provider()
    end,
    keys = {
      { '<leader>Ur', '<cmd>UNL refresh<CR>', desc = 'Unreal: Refresh project cache' },
      { '<leader>UR', '<cmd>UNL status<CR>', desc = 'Unreal: Server status' },
    },
  },

  -- Project navigation and symbol workflow.
  {
    'taku25/UEP.nvim',
    cond = is_ue_project,
    cmd = { 'UEP' },
    dependencies = { 'taku25/UNL.nvim' },
    opts = {
      ui = {
        picker = { mode = 'telescope', prefer = { 'telescope', 'native' } },
        grep_picker = { mode = 'telescope', prefer = { 'telescope', 'native' } },
      },
    },
    -- stylua: ignore
    keys = {
      { '<leader>Uf', '<cmd>UEP files<CR>', desc = 'Unreal: Find files' },
      { '<leader>Ug', '<cmd>UEP grep<CR>', desc = 'Unreal: Grep project' },
      { '<leader>Uc', '<cmd>UEP classes<CR>', desc = 'Unreal: Browse classes' },
      { '<leader>Us', '<cmd>UEP structs<CR>', desc = 'Unreal: Browse structs' },
      { '<leader>Ue', '<cmd>UEP enums<CR>', desc = 'Unreal: Browse enums' },
      { '<leader>Ui', '<cmd>UEP add_include<CR>', desc = 'Unreal: Add #include' },
      { '<leader>UG', '<cmd>UEP goto_definition<CR>', desc = 'Unreal: Go to definition' },
      { '<leader>UI', '<cmd>UEP goto_impl<CR>', desc = 'Unreal: Go to implementation' },
    },
  },

  -- Build, compile db, and UHT workflow.
  {
    'taku25/UBT.nvim',
    cond = is_ue_project,
    cmd = { 'UBT' },
    dependencies = { 'taku25/UNL.nvim' },
    opts = {
      preset_target = 'Win64DevelopWithEditor',
      use_last_preset_as_default = false,
      presets = ubt_presets or {},
    },
    -- stylua: ignore
    keys = {
      { '<leader>Ub', '<cmd>UBT build<CR>', desc = 'Unreal: Build' },
      { '<leader>UB', '<cmd>UBT build!<CR>', desc = 'Unreal: Build (pick target)' },
      { '<leader>Uj', '<cmd>UBT gen_compile_db<CR>', desc = 'Unreal: Generate compile_commands.json' },
      { '<leader>Uh', '<cmd>UBT gen_header<CR>', desc = 'Unreal: Generate headers (UHT)' },
      { '<leader>UJ', '<cmd>UBT gen_project<CR>', desc = 'Unreal: Generate .sln' },
      { '<leader>UE', '<cmd>UBT diagnostics<CR>', desc = 'Unreal: Build diagnostics' },
      { '<leader>UX', '<cmd>UBT run!<CR>', desc = 'Unreal: Run (pick target)' },
    },
  },

  -- Class and header/source workflow.
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
      { '<leader>Uk', '<cmd>UCM specifiers<CR>', desc = 'Unreal: Insert specifiers' },
      { '<leader>UO', '<cmd>UCM create_impl<CR>', desc = 'Unreal: Generate .cpp from .h' },
    },
  },

  -- Blueprint and asset references from C++.
  {
    'taku25/UEA.nvim',
    cond = is_ue_project,
    cmd = { 'UEA' },
    ft = { 'cpp', 'c' },
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

  -- UE debug launch integration.
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
      { '<leader>UD', '<cmd>UDB run_debug<CR>', desc = 'Unreal: Debug (default target)' },
      { '<leader>US', '<cmd>UDB run_debug!<CR>', desc = 'Unreal: Debug (select target)' },
    },
  },

  -- UE-specific completion source for blink.cmp.
  {
    'saghen/blink.cmp',
    cond = is_ue_project,
    optional = true,
    dependencies = {
      { 'taku25/blink-cmp-unreal' },
    },
    opts = {
      sources = {
        default = { 'unreal' },
        providers = {
          unreal = {
            module = 'blink-cmp-unreal',
            name = 'unreal',
            score_offset = 15,
          },
        },
      },
    },
  },
}
