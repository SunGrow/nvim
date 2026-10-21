-- Use centralized project context detection
local is_ue_project = require('core.context').is_ue

return {
  'neovim/nvim-lspconfig',
  event = { 'BufReadPre', 'BufNewFile' },
  dependencies = {
    { 'mason-org/mason.nvim', opts = {} },
    {
      'mason-org/mason-lspconfig.nvim',
      opts = {
        ensure_installed = { 'lua_ls', 'clangd' },
        automatic_enable = true,
      },
    },
    { 'saghen/blink.cmp' },
    {
      'folke/lazydev.nvim',
      ft = 'lua',
      opts = {
        library = {
          { path = '${3rd}/luv/library', words = { 'vim%.uv' } },
        },
      },
    },
  },
  config = function()
    -- Pass blink.cmp capabilities to all LSP servers
    local ok, blink = pcall(require, 'blink.cmp')
    local capabilities = ok and blink.get_lsp_capabilities() or {}

    -- Configure lua_ls via Neovim 0.11 native API
    vim.lsp.config('lua_ls', {
      capabilities = capabilities,
    })

    -- Mason only provides a clangd.cmd shim on Windows; stopping a client then kills cmd.exe and leaves
    -- clangd.exe running until it notices. Start the real executable when it is installed.
    local clangd_bin = vim.fn.glob(vim.fn.stdpath('data') .. '/mason/packages/clangd/*/bin/clangd.exe', false, true)
    clangd_bin = clangd_bin[#clangd_bin] or 'clangd'

    -- Build clangd command (UE-aware)
    local clangd_cmd = {
      clangd_bin,
      '--background-index',
      '--background-index-priority=background',
      '--completion-style=detailed',
      '--function-arg-placeholders=false',
      '-j=8',
      '--limit-results=500',
    }
    if is_ue_project then
      -- UE: no header insertion (iwyu breaks .generated.h include order),
      -- no clang-tidy (.clangd removes all checks anyway, saves init time),
      -- disk PCH storage (UE PCH files are 100MB+, memory mode causes OOM)
      vim.list_extend(clangd_cmd, {
        '--header-insertion=never',
        '--pch-storage=disk',
      })
    else
      vim.list_extend(clangd_cmd, {
        '--clang-tidy',
        '--header-insertion=iwyu',
        '--pch-storage=memory',
      })
    end

    -- UE: engine root comes from the project compile DB ("directory" is <root>/Engine/Source).
    -- Read on use: on a project's first open the DB is generated after startup (ue/compiledb.lua).
    local ctx = require('core.context')
    local engine_root_found
    local function engine_root()
      if engine_root_found or not is_ue_project then return engine_root_found end
      local f = io.open(ctx.ue_project_root .. '/compile_commands.json', 'r')
      if f then
        local dir = (f:read(8192) or ''):match('"directory"%s*:%s*"([^"]+)"')
        f:close()
        if dir then
          dir = vim.fs.normalize((dir:gsub('\\\\', '/')))
          engine_root_found = dir:match('^(.*)/Engine/Source/?$') or dir:match('^(.*)/Engine/')
        end
      end
      return engine_root_found
    end
    local function under(path, root)
      return root ~= nil and path:lower():sub(1, #root + 1) == root:lower() .. '/'
    end
    -- Engine .cpp files get their own clangd (synthesized compile DB from ue-lsp, no background index)
    local engine_cdb = vim.fs.normalize((vim.env.UE_LSP_CACHE_DIR or (vim.env.LOCALAPPDATA or '') .. '/ue-lsp/cache')
      .. '/engine-cdb')
    local function is_engine_cpp(path)
      return under(path, engine_root()) and path:match('%.cpp$') ~= nil
        and vim.uv.fs_stat(engine_cdb .. '/compile_commands.json') ~= nil
    end

    -- Configure clangd for C++
    -- NOTE: --offset-encoding removed — Neovim 0.11 negotiates encoding natively
    -- clangd.fileStatus: per-file parse state for the statusline (lua/core/clangd.lua)
    local clangd_status = {
      init_options = { clangdFileStatus = true },
      handlers = { ['textDocument/clangd.fileStatus'] = function(...) return require('core.clangd').on_file_status(...) end },
    }
    local clangd_conf = vim.tbl_extend('error', { capabilities = capabilities, cmd = clangd_cmd }, clangd_status)
    if is_ue_project then
      -- One compile DB for project files and the engine headers they include (otherwise an engine
      -- header has no root marker and Neovim starts a second, flag-less clangd for it).
      table.insert(clangd_cmd, '--compile-commands-dir=' .. ctx.ue_project_root)
      local markers = { '.clangd', '.clang-tidy', '.clang-format', 'compile_commands.json', 'compile_flags.txt', '.git' }
      clangd_conf.root_dir = function(bufnr, on_dir)
        local path = vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr))
        if is_engine_cpp(path) then return end -- clangd_engine
        if under(path, ctx.ue_project_root) or under(path, engine_root()) then return on_dir(ctx.ue_project_root) end
        on_dir(vim.fs.root(bufnr, markers))
      end
    end
    vim.lsp.config('clangd', clangd_conf)

    if is_ue_project then
      vim.lsp.config('clangd_engine', vim.tbl_extend('error', clangd_status, {
        capabilities = capabilities,
        cmd = {
          clangd_bin, '--compile-commands-dir=' .. engine_cdb, '--background-index=false',
          '--completion-style=detailed', '--function-arg-placeholders=false', '-j=2', '--limit-results=500',
          '--header-insertion=never', '--pch-storage=disk',
        },
        filetypes = { 'cpp' },
        root_dir = function(bufnr, on_dir)
          if is_engine_cpp(vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr))) then on_dir(engine_root()) end
        end,
      }))
      vim.lsp.enable('clangd_engine')
      -- Engine ASTs are large (~1 GB for Actor.cpp): stop the engine clangd once no engine .cpp
      -- buffer is left, so its memory is only spent while browsing engine code.
      vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
        group = vim.api.nvim_create_augroup('ue-engine-clangd-stop', { clear = true }),
        pattern = '*.cpp',
        callback = function(ev)
          vim.defer_fn(function()
            for _, c in ipairs(vim.lsp.get_clients({ name = 'clangd_engine' })) do
              local left = vim.tbl_filter(function(b)
                return b ~= ev.buf and vim.api.nvim_buf_is_loaded(b)
              end, vim.tbl_keys(c.attached_buffers))
              if #left == 0 then
                -- graceful shutdown, force-kill after 3 s (clangd otherwise lingers ~20 s finishing AST work);
                -- not `if not c:is_stopped()`: that is already true right after stop()
                c:stop(3000)
              end
            end
          end, 5000)
        end,
      })
    end

    -- ue-lsp (tools/ue-lsp in this config, or $UE_LSP_PATH): UE .ini keys/values,
    -- UPROPERTY/UFUNCTION specifier + meta hover/diagnostics. Not mason-managed, so enabled here.
    -- C++ specifier completion stays with blink-cmp-unreal (cpp.completion = false).
    local ue_lsp = vim.env.UE_LSP_PATH or vim.fs.normalize(vim.fn.stdpath('config') .. '/tools/ue-lsp/ue-lsp.py')
    if is_ue_project and vim.uv.fs_stat(ue_lsp) then
      vim.lsp.config('ue_ls', {
        capabilities = capabilities,
        cmd = { 'python', ue_lsp },
        filetypes = { 'dosini', 'cpp' },
        -- vim.fs.root does not take globs ('*.uproject'), so match with a function.
        -- Engine headers join the project's server too (Blueprint values of engine properties).
        root_dir = function(bufnr, on_dir)
          local root = vim.fs.root(bufnr, function(name) return name:match('%.uproject$') ~= nil end)
          if root then return on_dir(root) end
          local path = vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr))
          if under(path, engine_root()) and path:match('%.h$') then on_dir(ctx.ue_project_root) end
        end,
        init_options = { cpp = { completion = false } },
      })
      vim.lsp.enable('ue_ls')

      -- Blueprint/asset values of a UPROPERTY (code lens command + <leader>Uv)
      local function show_bp_values(res)
        if not res or not res.rows or #res.rows == 0 then
          return vim.notify('No Blueprint/asset values for this property', vim.log.levels.INFO)
        end
        local title = ('%s::%s (%d)'):format(res.class, res.prop, #res.rows)
        local ok_t, pickers = pcall(require, 'telescope.pickers')
        if not ok_t then
          return vim.ui.select(res.rows, {
            prompt = title,
            format_item = function(r) return ('%s  %s = %s'):format(r.name, r.object, r.value) end,
          }, function() end)
        end
        local finders, conf = require('telescope.finders'), require('telescope.config').values
        local actions, state = require('telescope.actions'), require('telescope.actions.state')
        local w = 8
        for _, r in ipairs(res.rows) do w = math.max(w, #r.name) end
        pickers.new({}, {
          prompt_title = 'Blueprint values: ' .. title,
          finder = finders.new_table({
            results = res.rows,
            entry_maker = function(r)
              local obj = (r.object == r.name or r.object == 'CDO') and '' or ('  [' .. r.object .. ']')
              local line = ('%-' .. w .. 's  %s%s'):format(r.name, r.value, obj)
              return { value = r, display = line, ordinal = line }
            end,
          }),
          sorter = conf.generic_sorter({}),
          attach_mappings = function(bufnr)
            actions.select_default:replace(function()
              local e = state.get_selected_entry()
              actions.close(bufnr)
              if e then
                vim.fn.setreg('+', e.value.asset)
                vim.notify('Copied ' .. e.value.asset)
              end
            end)
            return true
          end,
        }):find()
      end
      vim.lsp.commands['ue.bpValues'] = function(command, cctx)
        local client = vim.lsp.get_client_by_id(cctx.client_id)
        if not client then return end
        client:request('workspace/executeCommand', command, function(_, res) show_bp_values(res) end)
      end
      vim.keymap.set('n', '<leader>Uv', function()
        local client = vim.lsp.get_clients({ bufnr = 0, name = 'ue_ls' })[1]
        if not client then return vim.notify('ue_ls not attached', vim.log.levels.WARN) end
        client:request('workspace/executeCommand', {
          command = 'ue.bpValuesAt',
          arguments = { { uri = vim.uri_from_bufnr(0), line = vim.api.nvim_win_get_cursor(0)[1] - 1 } },
        }, function(_, res)
          if not res then return vim.notify('Not on a UPROPERTY declaration', vim.log.levels.INFO) end
          show_bp_values(res)
        end, 0)
      end, { desc = 'Unreal: Blueprint values of property' })
    end

    -- UE go-to-definition: clangd first; when it only knows a header declaration (engine modules are
    -- precompiled, their .cpp is not indexed), ask ue_ls for the out-of-line body in the owning module.
    local function ue_definition()
      local bufnr = vim.api.nvim_get_current_buf()
      local cl = vim.lsp.get_clients({ bufnr = bufnr, name = 'clangd' })[1]
        or vim.lsp.get_clients({ bufnr = bufnr, name = 'clangd_engine' })[1]
      local ue = vim.lsp.get_clients({ name = 'ue_ls' })[1]
      if not cl or not ue then return vim.lsp.buf.definition() end
      local params = vim.lsp.util.make_position_params(0, cl.offset_encoding)
      local function uri_of(l) return l.uri or l.targetUri end
      local function jump(l, enc) vim.lsp.util.show_document(l, enc, { focus = true }) end
      cl:request('textDocument/definition', params, function(_, res)
        local locs = res and (vim.islist(res) and res or { res }) or {}
        for _, l in ipairs(locs) do
          if uri_of(l):match('%.cpp$') or uri_of(l):match('%.inl$') then return jump(l, cl.offset_encoding) end
        end
        local first = locs[1]
        cl:request('textDocument/symbolInfo', params, function(_, info)
          local s = info and info[1]
          if not s or not s.name or s.name == '' then
            if first then jump(first, cl.offset_encoding) end
            return
          end
          local rng = first and (first.targetSelectionRange or first.range)
          local decl = first and { uri = uri_of(first), line = rng.start.line }
            or { uri = params.textDocument.uri, line = params.position.line }
          ue:request('workspace/executeCommand', {
            command = 'ue.findImpl',
            arguments = { { uri = decl.uri, line = decl.line, name = s.name, container = s.containerName or '' } },
          }, function(_, hits)
            if hits and #hits == 1 then return jump(hits[1], ue.offset_encoding) end
            if hits and #hits > 1 then
              vim.fn.setqflist({}, ' ', {
                title = 'Implementations of ' .. s.name,
                items = vim.lsp.util.locations_to_items(hits, ue.offset_encoding),
              })
              return vim.cmd('botright copen')
            end
            if first then jump(first, cl.offset_encoding) end
          end, bufnr)
        end, bufnr)
      end, bufnr)
    end

    -- LspAttach: buffer-local keymaps for non-default bindings
    vim.api.nvim_create_autocmd('LspAttach', {
      group = vim.api.nvim_create_augroup('lsp-attach', { clear = true }),
      callback = function(event)
        local map = function(keys, func, desc, mode)
          mode = mode or 'n'
          vim.keymap.set(mode, keys, func, { buffer = event.buf, desc = 'LSP: ' .. desc })
        end

        map('gd', is_ue_project and ue_definition or vim.lsp.buf.definition, 'Go to definition')

        -- Rider (VS Code keymap) keys; core.code asks clangd and opens a picker
        local code = require('core.code')
        map('<F12>', is_ue_project and ue_definition or vim.lsp.buf.definition, 'Go to definition')
        map('<M-CR>', code.actions, 'Quick fix / code actions', { 'n', 'i', 'x' })
        map('<C-.>', code.actions, 'Quick fix / code actions', { 'n', 'i', 'x' })
        map('<leader>ca', code.actions, 'Quick fix / code actions', { 'n', 'x' })
        map('<F2>', vim.lsp.buf.rename, 'Rename symbol')
        map('<leader>cr', vim.lsp.buf.rename, 'Rename symbol')
        map('<S-F12>', code.usages, 'Find usages')
        map('<S-M-F12>', code.usages, 'Find usages')
        map('<leader>cu', code.usages, 'Find usages')
        map('<leader>fu', code.usages, 'Find usages')
        map('<C-F12>', code.implementations, 'Go to implementation / overrides')
        map('<leader>cm', code.implementations, 'Go to implementation / overrides')
        map('<S-M-h>', function() code.calls('incoming') end, 'Callers (call hierarchy)')
        map('<leader>ch', function() code.calls('incoming') end, 'Callers (call hierarchy)')
        map('<leader>cH', function() code.calls('outgoing') end, 'Callees (call hierarchy)')
        map('<leader>cb', function() code.types('supertypes') end, 'Base classes')
        map('<leader>cd', function() code.types('subtypes') end, 'Derived classes')

        -- ue_ls code lens (Blueprint values on UPROPERTY lines in headers)
        local client = vim.lsp.get_client_by_id(event.data.client_id)
        if client and client.name == 'ue_ls' and vim.api.nvim_buf_get_name(event.buf):match('%.h$') then
          vim.lsp.codelens.refresh({ bufnr = event.buf })
          vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWritePost', 'InsertLeave' }, {
            buffer = event.buf,
            group = vim.api.nvim_create_augroup('ue-codelens-' .. event.buf, { clear = true }),
            callback = function() vim.lsp.codelens.refresh({ bufnr = event.buf }) end,
          })
          map('<leader>Ul', vim.lsp.codelens.run, 'Unreal: run code lens (Blueprint values)')
        end
        map('gD', vim.lsp.buf.declaration, 'Go to declaration')
        map('<leader>ld', vim.diagnostic.open_float, 'Diagnostics float')
        map('<leader>li', '<cmd>LspInfo<CR>', 'LSP info')

        -- clangd-specific: register ClangdSwitchSourceHeader command (used by <M-o>)
        if client and (client.name == 'clangd' or client.name == 'clangd_engine') then
          require('core.clangd').on_attach(client, event.buf) -- parse status, counterpart prewarming
          code.attach_highlight(client, event.buf)
          code.attach_hints(client, event.buf)
        end
        local clangd = vim.lsp.get_clients({ bufnr = event.buf, name = 'clangd' })[1]
        if clangd then
          vim.api.nvim_buf_create_user_command(event.buf, 'ClangdSwitchSourceHeader', function()
            local params = { uri = vim.uri_from_bufnr(event.buf) }
            clangd:request('textDocument/switchSourceHeader', params, function(err, result)
              if err or not result or result == '' then return end
              vim.cmd.edit(vim.uri_to_fname(result))
            end, event.buf)
          end, { desc = 'Switch between source/header (clangd)' })
        end

        -- Built-in 0.11 defaults (NOT overridden):
        -- grn = rename, gra = code action (n,v), grr = references
        -- gri = implementation, grt = type definition, gO = document symbols
        -- K = hover, <C-s> = signature help (i,s)
        -- CTRL-] = definition (via tagfunc), gq = format (via formatexpr)
        -- [d/]d = prev/next diagnostic, <C-W>d = diagnostic float
      end,
    })
  end,
}
