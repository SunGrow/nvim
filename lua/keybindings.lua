-- Keybinding.lua

-- Enhanced Keybinding utility functions for Lua functions
local function map(mode, shortcut, command)
  vim.api.nvim_set_keymap(mode, shortcut, command, { noremap = true, silent = true })
end

local function nmap(shortcut, command)
  map('n', shortcut, command)
end

local function imap(shortcut, command)
  map('i', shortcut, command)
end

-- Window and File Navigation
nmap("<leader>w", "<C-W>")
nmap("<leader>e", ":Ex<CR>")

-- Buffer Control
nmap("<A-,>", "<CMD>:BufferLineCyclePrev<CR>")
nmap("<A-.>", "<CMD>:BufferLineCycleNext<CR>")
nmap("<A-<>", "<CMD>:BufferLineMovePrev<CR>")
nmap("<A->>", "<CMD>:BufferLineMoveNext<CR>")
nmap("<leader>be", "<CMD>:BufferLineSortByExtension<CR>")
nmap("<leader>bd", "<CMD>:BufferLineSortByDirectory<CR>")
nmap("<A-<num>>", "<cmd>:lua require('bufferline').go_to_buffer(num)<CR>")
nmap("<A-c>", "<CMD>:bd<CR>")
nmap("<C-s>", "<CMD>:BufferLinePick<CR>")
nmap("<leader>q", "<CMD>:bp<bar>sp<bar>bn<bar>bd<CR>")

-- Exit terminal mode
-- nmap("<C-Esc>", "<C-\\><C-n>")
nmap("<leader><A-Esc>", ":bp<bar>sp<bar>bn<bar>bd!<CR>")

-- Clear search highlighting
nmap("<esc><esc>", ":noh<CR>")

-- Function to get Clangd write usages
function GetClangdWriteUsages()
    -- Prepare the parameters for the LSP request
    local params = vim.lsp.util.make_position_params()
    params.context = { includeDeclaration = false }  -- Optional: Exclude declarations

    -- Send the 'textDocument/references' request to Clangd
    vim.lsp.buf_request(0, 'textDocument/references', params, function(err, result, ctx, _)
        if err then
            vim.notify('Error retrieving references: ' .. err.message, vim.log.levels.ERROR)
            return
        end
        if not result or vim.tbl_isempty(result) then
            vim.notify('No references found', vim.log.levels.INFO)
            return
        end

        -- Filter references to include only write usages
        local write_references = {}
        for _, ref in ipairs(result) do
            -- Clangd provides 'ReferenceKind' in 'ref.kind'
            if ref.kind == 2 or ref.kind == 3 then  -- 2: Write, 3: ReadWrite
                table.insert(write_references, ref)
            end
        end

        if vim.tbl_isempty(write_references) then
            vim.notify('No write usages found', vim.log.levels.INFO)
            return
        end

        -- Populate the quickfix list with write usages and open it
        vim.fn.setqflist({}, ' ', { title = 'Write Usages', items = vim.lsp.util.locations_to_items(write_references) })
        vim.api.nvim_command('copen')
    end)
end

-- LSP Keymaps
LspOnAttach = function(client, bufnr)
  local opts = { noremap = true, silent = true }
  local lsp_buf = vim.lsp.buf

  vim.keymap.set('n', '<leader>dg', lsp_buf.declaration, opts)
  vim.keymap.set('n', 'gd', lsp_buf.definition, opts)
  vim.keymap.set('n', 'gD', function() Trouble.toggle("lsp_definitions") end, opts)
  vim.keymap.set('n', '<leader>r', lsp_buf.rename, opts)
  vim.keymap.set('n', '<F2>', lsp_buf.rename, opts)
  vim.keymap.set('n', '<leader>/', '<cmd>lua vim.lsp.buf.workspace_symbol(opts)<CR>', opts)
  vim.keymap.set('n', 'K', "<Cmd>lua vim.lsp.buf.hover()<CR>", opts)
  vim.keymap.set('n', '<A-]>', function() Trouble.toggle("lsp_references") end, opts)
  vim.keymap.set('n', '<A-[>', ':lua GetClangdWriteUsages()<CR>', { noremap = true, silent = true })
  vim.keymap.set('n', 'gi', '<cmd>Trouble lsp_implementations<CR>', opts)
  vim.keymap.set('n', 'g0', '<cmd>lua vim.lsp.buf.document_symbol()<CR>', opts)
  vim.keymap.set('n', '<leader>D', function() Trouble.toggle("lsp_type_definitions") end, opts)

  vim.keymap.set('n', '<leader>Wa', '<cmd>lua vim.lsp.buf.add_workspace_folder()<CR>', opts)
  vim.keymap.set('n', '<leader>Wr', '<cmd>lua vim.lsp.buf.remove_workspace_folder()<CR>', opts)
  vim.keymap.set('n', '<leader>Wl', '<cmd>lua print(vim.inspect(vim.lsp.buf.list_workspace_folders()))<CR>', opts)

  vim.keymap.set('n', '<A-Cr>', vim.lsp.buf.code_action, opts)
  vim.keymap.set('n', '<leader>aa', vim.lsp.buf.code_action, opts)
  vim.keymap.set('n', '<leader>wd', function() Trouble.toggle("diagnostics") end, opts)
  vim.keymap.set('n', '<leader>sh', "<cmd>lua vim.lsp.buf.document_highlight(opts)<CR>", opts)

  vim.keymap.set('n', '<leader>lc', '<cmd>LspRestart<cr>', opts)
end

-- Telescope Keymaps
local builtin = require('telescope.builtin')
vim.keymap.set('n', '<leader>ff', builtin.find_files, {})
vim.keymap.set('n', '<leader>fg', builtin.live_grep, {})
vim.keymap.set('n', '<leader>fb', builtin.buffers, {})
vim.keymap.set('n', '<leader>fh', builtin.help_tags, {})

-- CMake Keymaps
nmap("<leader>pg", "<CMD>:CMakeGenerate<CR>")
nmap("<leader>pb", "<CMD>:CMakeBuild<CR>")
nmap("<leader>pp", "<CMD>:CMakeRun<CR>")
nmap("<leader>pt", "<CMD>:CMakeRunTest<CR>")

-- Debug (DAP) Keymaps
local dap = require('dap')
vim.keymap.set('n', '<F5>', dap.continue, { noremap=true, silent=true })
vim.keymap.set('n', '<F10>', dap.step_over, { noremap=true, silent=true })
vim.keymap.set('n', '<F11>', dap.step_into, { noremap=true, silent=true })
vim.keymap.set('n', '<F12>', dap.step_out, { noremap=true, silent=true })

vim.keymap.set('n', '<Leader>b', dap.toggle_breakpoint, { noremap=true, silent=true })
vim.keymap.set('n', '<Leader>B', function() require('dap').set_breakpoint() end)
vim.keymap.set('n', '<Leader>lp', function() require('dap').set_breakpoint(nil, nil, vim.fn.input('Log point message: ')) end)
vim.keymap.set('n', '<Leader>dr', function() require('dap').repl.open() end)
vim.keymap.set('n', '<Leader>dl', function() require('dap').run_last() end)
vim.keymap.set({'n', 'v'}, '<Leader>dh', function()
  require('dap.ui.widgets').hover()
end)
vim.keymap.set({'n', 'v'}, '<Leader>dp', function()
  require('dap.ui.widgets').preview()
end)
vim.keymap.set('n', '<Leader>df', function()
  local widgets = require('dap.ui.widgets')
  widgets.centered_float(widgets.frames)
end)
vim.keymap.set('n', '<Leader>ds', function()
  local widgets = require('dap.ui.widgets')
  widgets.centered_float(widgets.scopes)
end)

local dapui = require("dapui")
vim.keymap.set('n', '<Leader>u', dapui.toggle, { noremap=true, silent=true })
vim.keymap.set('n', '<Leader>de', dapui.eval, { noremap=true, silent=true })
dapui.setup()

-- === New Section: CodeCompanion Keybindings ===
-- Adding keybindings for olimorris/codecompanion.nvim
-- Prefix: <leader>c

-- vim.api.nvim_set_keymap('n', '<leader>cc', ':CodeCompanionChat<CR>', { noremap = true, silent = true })
-- vim.api.nvim_set_keymap('v', '<leader>cf', ':CodeCompanionFormat<CR>', { noremap = true, silent = true })
