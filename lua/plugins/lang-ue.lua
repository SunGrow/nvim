-- Unreal Engine 5 development support (taku25 suite)
-- Zero overhead outside UE projects: all specs use cond = is_ue_project

-- Use centralized project context detection
local ctx = require('core.context')
local is_ue_project = ctx.is_ue
local project_name = ctx.ue_project_name

-- Common gameplay framework parent classes — guaranteed available even before UNL DB scan completes.
-- Also serve as Tier 1 (highest priority) in the parent picker ordering.
local ENGINE_BASE_CLASSES = {
  'UObject',
  'AActor', 'APawn', 'ACharacter', 'ADefaultPawn',
  'AController', 'APlayerController', 'AAIController',
  'AGameModeBase', 'AGameMode',
  'AGameStateBase', 'AGameState',
  'APlayerState', 'AInfo',
  'AHUD', 'APlayerCameraManager',
  'UActorComponent', 'USceneComponent',
  'UGameInstanceSubsystem', 'UWorldSubsystem', 'ULocalPlayerSubsystem',
  'UGameInstance',
  'UUserWidget',
  'UBlueprintFunctionLibrary',
  'UAnimInstance',
  'UDeveloperSettings',
  'UPrimaryDataAsset', 'UDataAsset',
}
local ENGINE_BASE_SET = {}
for _, name in ipairs(ENGINE_BASE_CLASSES) do ENGINE_BASE_SET[name] = true end

local ENGINE_BASE_STRUCTS = { 'FTableRowBase' }
local ENGINE_BASE_STRUCT_SET = {}
for _, name in ipairs(ENGINE_BASE_STRUCTS) do ENGINE_BASE_STRUCT_SET[name] = true end

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
  local project_root = ctx.ue_project_root
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
      { '<leader>Uc', '<cmd>UEP classes<CR>', desc = 'Unreal: Browse classes' },
      { '<leader>Us', '<cmd>UEP structs<CR>', desc = 'Unreal: Browse structs' },
      { '<leader>Ue', '<cmd>UEP enums<CR>', desc = 'Unreal: Browse enums' },
      { '<leader>UG', '<cmd>UEP goto_definition<CR>', desc = 'Unreal: Go to definition' },
      { '<leader>UI', '<cmd>UEP goto_impl<CR>', desc = 'Unreal: Go to implementation' },
      { '<leader>ci', '<cmd>UEP add_include<CR>', desc = 'Add #include' },
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
      { '<leader>bb', '<cmd>UBT build<CR>', desc = 'Build' },
      { '<leader>bB', '<cmd>UBT build!<CR>', desc = 'Build (pick target)' },
      { '<leader>bj', '<cmd>UBT gen_compile_db<CR>', desc = 'Generate compile_commands.json' },
      { '<leader>bJ', '<cmd>UBT gen_project<CR>', desc = 'Generate .sln' },
      { '<leader>be', '<cmd>UBT diagnostics<CR>', desc = 'Build diagnostics' },
      { '<leader>bx', '<cmd>UBT run!<CR>', desc = 'Run (pick target)' },
      { '<leader>Uh', '<cmd>UBT gen_header<CR>', desc = 'Unreal: Generate headers (UHT)' },
    },
  },

  -- Class and header/source workflow.
  {
    'taku25/UCM.nvim',
    cond = is_ue_project,
    cmd = { 'UCM' },
    dependencies = { 'taku25/UNL.nvim' },
    opts = {},
    config = function(_, opts)
      require('UCM').setup(opts)
      -- Patch UCM logger: cmd/new.lua calls log.warn() on the module table,
      -- but the module only exposes .get() — proxy log level methods through.
      local ucm_logger = require('UCM.logger')
      for _, level in ipairs({ 'warn', 'info', 'error', 'debug', 'trace' }) do
        if not ucm_logger[level] then
          ucm_logger[level] = function(...)
            return ucm_logger.get()[level](...)
          end
        end
      end
    end,
    -- stylua: ignore
    keys = {
      { '<leader>Un', function()
          -- Wrapper: bypass broken cmd/new.lua (double-prompt + value unwrap bug).
          -- Pre-fetches parent classes/structs immediately so the parent picker is instant.
          -- Flow: resolve module → class/struct → pick directory → name → parent picker → UCM direct.
          local project_root = ctx.ue_project_root
          local find_module_root = require('UNL.finder').module.find_module_root
          local unl_db = require('UNL.db')

          -- Pre-fetch classes AND structs immediately (async, runs in background).
          -- By the time the user picks module → kind → directory → name, data is ready.
          local prefetch = { classes = nil, structs = nil }
          local class_data_map = {}
          local struct_data_map = {}

          unl_db.get_classes(
            { extra_where = "AND (c.symbol_type = 'class' OR c.symbol_type = 'UCLASS')" },
            function(result)
              prefetch.classes = {}
              if result then
                for _, info in ipairs(result) do
                  local name = info.name
                  if name and name:match('^[a-zA-Z_][a-zA-Z0-9_]*$') then
                    table.insert(prefetch.classes, {
                      value = name,
                      display = string.format('%s  (%s)', name, vim.fn.fnamemodify(info.path or '', ':t')),
                      filename = info.path,
                      module_name = info.module_name,
                    })
                    class_data_map[name] = { header_file = info.path, base_class = info.base_class, module_name = info.module_name }
                  end
                end
              end
            end
          )

          unl_db.get_classes(
            { extra_where = "AND (c.symbol_type = 'struct' OR c.symbol_type = 'USTRUCT')" },
            function(result)
              prefetch.structs = {}
              if result then
                for _, info in ipairs(result) do
                  local name = info.name
                  if name and name:match('^[a-zA-Z_][a-zA-Z0-9_]*$') then
                    table.insert(prefetch.structs, {
                      value = name,
                      display = string.format('%s  (%s)', name, vim.fn.fnamemodify(info.path or '', ':t')),
                      filename = info.path,
                      module_name = info.module_name,
                    })
                    struct_data_map[name] = { header_file = info.path, base_struct = info.base_class, module_name = info.module_name }
                  end
                end
              end
            end
          )

          -- Step 5: show parent picker from pre-fetched data, then call UCM direct mode
          -- Uses UNL streaming picker (proven with 57K+ entries) instead of raw Telescope finders.new_table.
          -- Entries are priority-sorted: Engine base > main game module > plugins > everything else.
          local function show_parent_picker(kind, cls_name, target_dir)
            local choices = kind == 'Class' and prefetch.classes or prefetch.structs

            -- If still loading, poll briefly (data should arrive any moment)
            if not choices then
              local attempts = 0
              local function poll()
                attempts = attempts + 1
                choices = kind == 'Class' and prefetch.classes or prefetch.structs
                if choices then
                  show_parent_picker(kind, cls_name, target_dir)
                elseif attempts < 20 then
                  vim.defer_fn(poll, 300)
                else
                  vim.notify('[UCM] Timed out loading parent data', vim.log.levels.ERROR)
                end
              end
              vim.notify('[UCM] Loading parent classes...', vim.log.levels.INFO)
              vim.defer_fn(poll, 300)
              return
            end

            if #choices == 0 then
              vim.notify('[UCM] No parent classes/structs found', vim.log.levels.WARN)
              return
            end

            -- Build priority-sorted list: Tier 1 (engine base) > Tier 2 (main module) > Tier 3 (plugins) > Tier 4 (rest)
            local base_set = kind == 'Class' and ENGINE_BASE_SET or ENGINE_BASE_STRUCT_SET
            local static_list = kind == 'Class' and ENGINE_BASE_CLASSES or ENGINE_BASE_STRUCTS
            local tiers = { {}, {}, {}, {} }
            local seen = {}

            for _, item in ipairs(choices) do
              if not seen[item.value] then
                seen[item.value] = true
                local tier
                if base_set[item.value] then
                  tier = 1
                elseif item.module_name == project_name then
                  tier = 2
                elseif item.filename and item.filename:find('/Plugins/', 1, true) then
                  tier = 3
                else
                  tier = 4
                end
                table.insert(tiers[tier], item)
              end
            end

            -- Add static engine classes not already found in DB
            for _, name in ipairs(static_list) do
              if not seen[name] then
                seen[name] = true
                table.insert(tiers[1], { value = name, display = name .. '  (Engine)', filename = '' })
              end
            end

            -- Sort each tier alphabetically, then concatenate
            local sorted = {}
            for _, bucket in ipairs(tiers) do
              table.sort(bucket, function(a, b) return a.value < b.value end)
              for _, item in ipairs(bucket) do
                table.insert(sorted, item)
              end
            end

            -- Use UNL streaming picker (routes through patched run_callback)
            local data_map = kind == 'Class' and class_data_map or struct_data_map
            require('UNL.picker').open({
              kind = 'ucm_parent_picker',
              title = kind == 'Class' and '  Select Parent Class' or '  Select Parent Struct',
              source = {
                type = 'callback',
                fn = function(push)
                  push(sorted)
                end,
              },
              preview_enabled = true,
              on_confirm = function(selected)
                if not selected then return end
                local parent = type(selected) == 'table' and selected.value or selected
                -- Regenerate compile_commands.json so clangd picks up the new files
                local function on_complete(success)
                  if success then
                    vim.cmd('UBT gen_compile_db')
                  end
                end
                if kind == 'Class' then
                  local header = data_map[parent] and data_map[parent].header_file
                  require('UCM.api').new_class({
                    class_name = cls_name,
                    parent_class = parent,
                    target_dir = target_dir,
                    parent_class_header = header,
                    skip_confirmation = true,
                    on_complete = on_complete,
                  })
                else
                  require('UCM.api').new_struct({
                    struct_name = cls_name,
                    parent_struct = parent,
                    target_dir = target_dir,
                    skip_confirmation = true,
                    on_complete = on_complete,
                  })
                end
              end,
            })
          end

          -- Step 4: ask for name, then show parent picker
          local function ask_name_and_dispatch(kind, target_dir)
            vim.ui.input({ prompt = 'New ' .. kind:lower() .. ' name: ' }, function(cls_name)
              if not cls_name or cls_name == '' then return end
              show_parent_picker(kind, cls_name, target_dir)
            end)
          end

          -- Step 3: scan subdirs within module via fd, let user pick
          local function pick_dir_and_dispatch(module_root, kind)
            local fd_cmd = {
              'fd', '.', module_root,
              '--type', 'd',
              '--path-separator', '/',
              '--exclude', 'Intermediate',
              '--exclude', 'Binaries',
              '--exclude', 'Saved',
            }
            vim.system(fd_cmd, { text = true }, vim.schedule_wrap(function(result)
              local dirs = {}
              local root_display = vim.fn.fnamemodify(module_root, ':t')
              table.insert(dirs, { display = root_display .. '/ (module root)', path = module_root })
              if result.code == 0 and result.stdout ~= '' then
                for line in result.stdout:gmatch('[^\r\n]+') do
                  local rel = line:sub(#module_root + 2)
                  if rel ~= '' then
                    table.insert(dirs, { display = rel, path = line })
                  end
                end
              end

              if #dirs == 1 then
                ask_name_and_dispatch(kind, module_root)
                return
              end

              local pickers = require('telescope.pickers')
              local finders = require('telescope.finders')
              local conf = require('telescope.config').values
              local actions = require('telescope.actions')
              local action_state = require('telescope.actions.state')

              pickers.new({}, {
                prompt_title = 'Select target directory',
                finder = finders.new_table({
                  results = dirs,
                  entry_maker = function(entry)
                    return { value = entry.path, display = entry.display, ordinal = entry.display }
                  end,
                }),
                sorter = conf.generic_sorter({}),
                attach_mappings = function(bufnr)
                  actions.select_default:replace(function()
                    local entry = action_state.get_selected_entry()
                    actions.close(bufnr)
                    if not entry then return end
                    ask_name_and_dispatch(kind, entry.value)
                  end)
                  return true
                end,
              }):find()
            end))
          end

          -- Step 2: class/struct selection, then directory picker
          local function dispatch(module_root)
            vim.ui.select({ 'Class', 'Struct' }, { prompt = 'Create:' }, function(kind)
              if not kind then return end
              pick_dir_and_dispatch(module_root, kind)
            end)
          end

          -- Step 1: resolve module from buffer or scan project
          local buf_dir = vim.fn.expand('%:p:h')
          local module_root = find_module_root(buf_dir)

          if module_root then
            dispatch(module_root)
            return
          end

          -- Not in a module — scan Source/ and Plugins/*/Source/ for .Build.cs
          local modules = {}
          local scan_dirs = { project_root .. '/Source' }
          local plugins_dir = project_root .. '/Plugins'
          if vim.fn.isdirectory(plugins_dir) == 1 then
            for name, type in vim.fs.dir(plugins_dir) do
              if type == 'directory' then
                local plugin_src = plugins_dir .. '/' .. name .. '/Source'
                if vim.fn.isdirectory(plugin_src) == 1 then
                  table.insert(scan_dirs, plugin_src)
                end
              end
            end
          end
          for _, scan_dir in ipairs(scan_dirs) do
            if vim.fn.isdirectory(scan_dir) == 1 then
              for name, type in vim.fs.dir(scan_dir) do
                if type == 'directory' then
                  local candidate = scan_dir .. '/' .. name
                  if find_module_root(candidate) then
                    table.insert(modules, { name = name, path = candidate })
                  end
                end
              end
            end
          end

          if #modules == 0 then
            vim.notify('[UCM] No UE modules found under Source/', vim.log.levels.ERROR)
          elseif #modules == 1 then
            dispatch(modules[1].path)
          else
            vim.ui.select(modules, {
              prompt = 'Select target module:',
              format_item = function(m) return m.name end,
            }, function(choice)
              if choice then
                dispatch(choice.path)
              end
            end)
          end
        end, desc = 'Unreal: New class/struct' },
      { '<leader>Uk', '<cmd>UCM specifiers<CR>', desc = 'Unreal: Insert specifiers' },
      { '<leader>cI', '<cmd>UCM create_impl<CR>', desc = 'Generate .cpp from .h' },
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
      { '<leader>bD', '<cmd>UDB run_debug<CR>', desc = 'Debug (default target)' },
      { '<leader>bS', '<cmd>UDB run_debug!<CR>', desc = 'Debug (select target)' },
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
