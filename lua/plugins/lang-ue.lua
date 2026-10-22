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
-- Only for UNL versions that still route callback sources through provider.run_callback
-- (up to 2026-02); later UNL rewrote the provider (prepare_source + behaviour modes) and has no such hook.
local function patch_unl_telescope_provider()
  local ok, provider = pcall(require, 'UNL.backend.picker.provider.telescope')
  if not ok or type(provider) ~= 'table' or provider._lazyf_patch_applied
    or type(provider.run_callback) ~= 'function' then
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

if is_ue_project or ctx.wsl_ue or ctx.ue_unix then
  -- UE Coding Standards: tabs with width 4 for C/C++ files, also in a UE project opened from WSL / Linux /
  -- macOS (2-wide tabs there misaligned UE source)
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
end

-- Auto-create .clangd when in a UE project
if is_ue_project then
  local project_root = ctx.ue_project_root
  local clangd_path = project_root .. '/.clangd'
  -- shadow *.generated.h first: GENERATED_BODY() stays valid when lines move before the next build
  -- (lua/ue/uht_shadow.lua)
  local uht_flag = require('ue.uht_shadow').clangd_flag()
  local clangd_config = table.concat({
    'CompileFlags:',
    '  Add: [-D__INTELLISENSE__, ' .. uht_flag .. ', -Wno-everything]',
    -- -resource-dir: UBT points it at Visual Studio's clang 19 headers. With those, clangd 20's
    -- background index records every parameter whose type is a template with a default argument
    -- (TArray, TMap, TSet, TSharedPtr, std::vector...) as `int`, so usages, overrides and callers of
    -- such functions are lost. clangd's own headers are used instead.
    '  Remove: [/Yu*, /Yc*, /Fp*, -include-pch, -resource-dir]',
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
    -- UHT .gen.cpp and other build outputs: each costs a full UnrealEd parse in the background index
    -- (~45 s CPU) and only adds Z_Construct_* noise to symbol search. Opened files still work.
    '---',
    'If:',
    '  PathMatch: Intermediate/.*',
    'Index:',
    '  Background: Skip',
    '',
  }, '\n')

  local should_write = vim.fn.filereadable(clangd_path) == 0
  if not should_write then
    local existing = table.concat(vim.fn.readfile(clangd_path), '\n')
    local managed_by_this_config = existing:find('-D__INTELLISENSE__', 1, true) ~= nil
    local strips_required_forced_includes = existing:find('/FI*', 1, true) ~= nil
      or existing:find('-include]', 1, true) ~= nil
      or existing:find('-include,', 1, true) ~= nil
    local indexes_intermediate = not existing:find('Background: Skip', 1, true)
    local keeps_resource_dir = not existing:find('-resource-dir', 1, true)
    local lacks_uht_shadow = not existing:find(uht_flag, 1, true)
    if managed_by_this_config and (strips_required_forced_includes or indexes_intermediate or keeps_resource_dir or lacks_uht_shadow) then
      should_write = true
    end
  end

  if should_write then
    vim.fn.writefile(vim.split(clangd_config, '\n'), clangd_path)
    vim.schedule(function() vim.notify('Updated .clangd in ' .. project_root, vim.log.levels.INFO, { title = 'clangd' }) end)
  end

  -- An index built with UBT's -resource-dir has the wrong symbol for every function taking a
  -- TArray/TMap/... (see above), and clangd never re-indexes for changed flags: rebuild it once.
  -- Done before clangd starts (it runs when lazy reads this spec); with clangd already running
  -- (a hot reload) only ask for a restart.
  local cache = project_root .. '/.cache/clangd'
  local marker = cache .. '/nvim-index-v2' -- written once the index is built with the current flags
  if not vim.uv.fs_stat(marker) then
    local index = cache .. '/index'
    if vim.uv.fs_stat(index) and #vim.lsp.get_clients({ name = 'clangd' }) > 0 then
      vim.schedule(function()
        vim.notify('clangd index needs a rebuild (wrong symbols for TArray/TMap parameters): restart Neovim',
          vim.log.levels.WARN, { title = 'clangd' })
      end)
    else
      local ok = true
      if vim.uv.fs_stat(index) then
        local old = index .. '.old-' .. os.time()
        ok = vim.uv.fs_rename(index, old) ~= nil
        if ok then
          vim.system({ 'cmd.exe', '/c', 'rmdir', '/s', '/q', (old:gsub('/', '\\')) })
          vim.schedule(function() -- after startup: fidget shows it instead of a hit-enter prompt
            vim.notify('Rebuilding the clangd index (the old one had wrong symbols for TArray/TMap parameters); '
              .. 'find usages fills in as it progresses', vim.log.levels.INFO, { title = 'clangd' })
          end)
        end
      end
      if ok then
        vim.fn.mkdir(cache, 'p')
        vim.fn.writefile({ 'clangd background index built without UBT -resource-dir' }, marker)
        require('ue.clangd_index').mark_rebuilding() -- more clangd threads until it is built
      end
    end
  end

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

  -- Reopen last files when started in the project without arguments (lua/ue/session.lua).
  require('ue.session').setup()
end

-- UNL startup race: unl-server registers the project a few hundred ms after it starts, but UEA's code lens
-- queries the first buffer before that. The query fails with "Project not found" (or ECONNREFUSED while
-- the server is still starting), UEA reports it as an error (an ENTER prompt at startup) and the first
-- file never gets its lenses. Retry those transient errors for up to 10 s.
local function patch_unl_startup_retry()
  local ok, db = pcall(require, 'UNL.db')
  if not ok or type(db) ~= 'table' or db._lazyf_retry_applied or type(db.get_file_symbols) ~= 'function' then
    return
  end

  db._lazyf_retry_applied = true
  local get_file_symbols = db.get_file_symbols

  db.get_file_symbols = function(file_path, callback)
    local tries = 0
    local function attempt()
      get_file_symbols(file_path, function(result, err)
        local msg = err and tostring(err) or ''
        local transient = msg:find('Project not found', 1, true) or msg:find('ECONNREFUSED', 1, true)
        if transient and callback and tries < 20 then
          tries = tries + 1
          vim.defer_fn(attempt, 500)
        elseif callback then
          callback(result, err)
        end
      end)
    end
    attempt()
  end
end

-- UNL's index keeps directories as path components (Prefix "D:", RootDir "/", ...) and rebuilds them as
-- `D:///Development/...` (scanner/src/db/path.rs PATH_CTE). Windows opens that, but Neovim names the buffer
-- `D:\\\Development\...`: a second buffer for an open file, and an LSP URI that matches neither
-- compile_commands.json nor clangd's index, so clangd parses it cold (minutes during background indexing).
-- Results are rewritten to `D:/...`, which is also what the server accepts as input (to_db_path_format).
local function fix_path(s)
  if s:byte(2) == 58 and s:find('^%a:[/\\][/\\]') then return (s:gsub('^(%a:)[/\\]+', '%1/')) end
  return s
end

local function fix_paths(v)
  if type(v) == 'string' then return fix_path(v) end
  if type(v) == 'table' then
    for k, x in pairs(v) do
      if type(x) == 'string' then
        v[k] = fix_path(x)
      elseif type(x) == 'table' then
        fix_paths(x)
      end
    end
  end
  return v
end

local function patch_unl_paths()
  local ok, remote = pcall(require, 'UNL.db.remote')
  if not ok or type(remote) ~= 'table' or remote._lazyf_paths_applied then return end
  remote._lazyf_paths_applied = true
  local request, request_streaming = remote.request, remote.request_streaming
  remote.request = function(kind, args, callback)
    return request(kind, args, callback and function(result, err) callback(fix_paths(result), err) end)
  end
  remote.request_streaming = function(kind, args, on_partial, on_complete)
    return request_streaming(kind, args, on_partial and function(items) on_partial(fix_paths(items)) end, on_complete)
  end
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
      -- UNL.cmd.start is loaded (by UNL's plugin/ script) before setup creates the 'UNL' logger, so
      -- it keeps the fallback logger, which print()s every INFO line ("INFO: Registering and
      -- initializing project ...") on the command line at each start. Reload it now that the logger
      -- exists, into the same table so earlier references see the new functions.
      local old = package.loaded['UNL.cmd.start']
      if type(old) == 'table' then
        package.loaded['UNL.cmd.start'] = nil
        local ok, new = pcall(require, 'UNL.cmd.start')
        if ok and type(new) == 'table' then
          for k, v in pairs(new) do old[k] = v end
        end
        package.loaded['UNL.cmd.start'] = old
      end
      patch_unl_telescope_provider()
      patch_unl_startup_retry()
      patch_unl_paths()
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
    -- compile_commands.json is generated and refreshed by itself (lua/ue/compiledb.lua)
    init = function() require('ue.compiledb').setup() end,
    -- Presets are generated like Rider's run configurations (lua/ue/run.lua): one per
    -- Source/*.Target.cs target x buildable configuration, named "DebugGame Editor", "Development", ...
    -- UBT's own dynamic presets (every target UNL knows x every configuration) are not used.
    opts = function()
      local run = require('ue.run')
      local dev_editor = vim.tbl_filter(function(c)
        return c.type == 'Editor' and c.configuration == 'Development'
      end, run.list())[1]
      return {
        preset_target = dev_editor and dev_editor.name or 'Development Editor', -- compile DB / plain :UBT build
        use_last_preset_as_default = false,
        presets = run.ubt_presets(),
        -- UBT logs every compiler warning at WARN, and the default echo level (warn) prints each one
        -- with nvim_echo: a long line raises a hit-enter prompt that stalls the build output (and
        -- with it the launch after the build) until ENTER. Keep the log file; ue.run reports the result.
        logging = { echo = { level = 'off' }, notify = { level = 'off' } },
      }
    end,
    -- Rider (VS Code keymap) equivalents: F5 debug / Shift+F5 stop live in lang-cpp.lua with nvim-dap.
    -- stylua: ignore
    keys = {
      { '<C-F5>', function() require('ue.run').run() end, desc = 'Run selected configuration (no debugger)' },
      { '<C-S-b>', function() require('ue.run').build() end, desc = 'Build selected configuration' },
      { '<leader>bc', function() require('ue.run').pick() end, desc = 'Choose run configuration' },
      { '<leader>bb', function() require('ue.run').build() end, desc = 'Build selected configuration' },
      { '<leader>bB', function() require('ue.run').pick(require('ue.run').build) end, desc = 'Build (pick configuration)' },
      { '<leader>bD', function() require('ue.run').debug() end, desc = 'Debug selected configuration' },
      { '<leader>bS', function() require('ue.run').pick(require('ue.run').debug) end, desc = 'Debug (pick configuration)' },
      { '<leader>bx', function() require('ue.run').run() end, desc = 'Run selected configuration' },
      { '<leader>bX', function() require('ue.run').pick(require('ue.run').run) end, desc = 'Run (pick configuration)' },
      { '<leader>bR', function() require('ue.run').run_no_build() end, desc = 'Run selected without building' },
      { '<leader>bs', function() require('ue.run').stop() end, desc = 'Stop (debug session / run / build)' },
      { '<leader>bj', function() require('ue.compiledb').generate('<leader>bj') end, desc = 'Regenerate compile_commands.json' },
      { '<leader>bJ', '<cmd>UBT gen_project<CR>', desc = 'Generate .sln' },
      { '<leader>be', '<cmd>UBT diagnostics<CR>', desc = 'Build diagnostics' },
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

            -- Use UNL streaming picker. UNL >= 2026-07 needs the caller's plugin config (`conf`,
            -- for ui.picker.behaviour); without it the telescope provider errors and nothing is shown.
            local data_map = kind == 'Class' and class_data_map or struct_data_map
            require('UNL.picker').open({
              kind = 'ucm_parent_picker',
              conf = require('UCM.config').get(),
              logger_name = 'UCM',
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
                    require('ue.compiledb').generate('new ' .. cls_name)
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
    -- dbgeng adapter is registered in lang-cpp.lua when tools/dbgeng-dap exists; else UDB's codelldb default
    opts = {
      debugger = {
        adapter_type = vim.uv.fs_stat(vim.env.DBGENG_DAP_PATH
          or vim.fs.normalize(vim.fn.stdpath('config') .. '/tools/dbgeng-dap/dbgeng-dap.py')) and 'dbgeng' or 'codelldb',
      },
    },
    -- Launch keys are the generated run configurations (UBT spec above); :UDB stays available.
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
