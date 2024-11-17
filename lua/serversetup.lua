-- IMPORTANT: make sure to setup neodev BEFORE lspconfig
require("neodev").setup({
  -- add any options here, or leave empty to use the default settings
})

-- then setup your lsp server as usual
local lspconfig = require('lspconfig')

-- example to setup lua_ls and enable call snippets
lspconfig.lua_ls.setup({
  settings = {
    Lua = {
      completion = {
        callSnippet = "Replace"
      }
    }
  }
})



local configs = require('lspconfig/configs')
local util = require('lspconfig/util')

local completion = require('cmp_nvim_lsp')
local capabilities = vim.lsp.protocol.make_client_capabilities()
capabilities.textDocument.completion.completionItem.snippetSupport = true
capabilities = completion.default_capabilities(capabilities)

local function make_config()
  return {
    -- enable snippet support
    capabilities = capabilities,
    -- map buffer local keybindings when the language server attaches
   	on_attach = LspOnAttach,
	root_dir = util.root_pattern(
          '.git',
          '.clangd',
          '.clang-tidy',
          '.clang-format',
          'compile_commands.json',
          'compile_flags.txt',
          'configure.ac'
       ) or vim.loop.os_homedir()
  }
end

Lspconfig.clangd.setup{on_attach=LspOnAttach,
	cmd = { "clangd", "--background-index", "--clang-tidy", "-j=15", "--header-insertion=never", "--completion-style=detailed", "--cross-file-rename", "--suggest-missing-includes", "--pch-storage=memory"},
	root_dir = util.root_pattern("compile_commands.json", "compile_flags.txt", ".git") or vim.loop.os_homedir(),
	opts = make_config(),
	capabilities = capabilities,
}

require("typescript-tools").setup {
  on_attach = LspOnAttach,
  handlers = { ... },
  capabilities = capabilities,
  settings = {
    -- spawn additional tsserver instance to calculate diagnostics on it
    separate_diagnostic_server = true,
    -- "change"|"insert_leave" determine when the client asks the server about diagnostic
    publish_diagnostic_on = "insert_leave",
    -- array of strings("fix_all"|"add_missing_imports"|"remove_unused"|
    -- "remove_unused_imports"|"organize_imports") -- or string "all"
    -- to include all supported code actions
    -- specify commands exposed as code_actions
    expose_as_code_action = {},
    -- string|nil - specify a custom path to `tsserver.js` file, if this is nil or file under path
    -- not exists then standard path resolution strategy is applied
    tsserver_path = nil,
    -- specify a list of plugins to load by tsserver, e.g., for support `styled-components`
    -- (see 💅 `styled-components` support section)
    tsserver_plugins = {},
    -- this value is passed to: https://nodejs.org/api/cli.html#--max-old-space-sizesize-in-megabytes
    -- memory limit in megabytes or "auto"(basically no limit)
    tsserver_max_memory = "auto",
    -- described below
    tsserver_format_options = {},
    tsserver_file_preferences = {},
    -- locale of all tsserver messages, supported locales you can find here:
    -- https://github.com/microsoft/TypeScript/blob/3c221fc086be52b19801f6e8d82596d04607ede6/src/compiler/utilitiesPublic.ts#L620
    tsserver_locale = "en",
    -- mirror of VSCode's `typescript.suggest.completeFunctionCalls`
    complete_function_calls = false,
    include_completions_with_insert_text = true,
    -- CodeLens
    -- WARNING: Experimental feature also in VSCode, because it might hit performance of server.
    -- possible values: ("off"|"all"|"implementations_only"|"references_only")
    code_lens = "off",
    -- by default code lenses are displayed on all referencable values and for some of you it can
    -- be too much this option reduce count of them by removing member references from lenses
    disable_member_code_lens = true,
    -- JSXCloseTag
    -- WARNING: it is disabled by default (maybe you configuration or distro already uses nvim-ts-autotag,
    -- that maybe have a conflict if enable this feature. )
    jsx_close_tag = {
        enable = false,
        filetypes = { "javascriptreact", "typescriptreact" },
    }
  },
}


-- Configure lua language server for neovim development
-- local lua_settings = {
--   Lua = {
--     runtime = {
--       -- LuaJIT in the case of Neovim
--       version = 'LuaJIT',
--       path = vim.split(package.path, ';'),
--     },
--     diagnostics = {
--       -- Get the language server to recognize the `vim` global
--       globals = {'vim'},
--     },
--     workspace = {
--       -- Make the server aware of Neovim runtime files
--       library = {
--         [vim.fn.expand('$VIMRUNTIME/lua')] = true,
--         [vim.fn.expand('$VIMRUNTIME/lua/vim/lsp')] = true,
--       },
--     },
--   }
-- }
-- lspconfig.lua.setup{settings=lua_settings, opts = make_config()}
Lspconfig.lua_ls.setup{
	opts = make_config(),
   	on_attach = LspOnAttach,
	capabilities = capabilities,
}

Lspconfig.cmake.setup{
	opts = make_config(),
   	on_attach = LspOnAttach,
	capabilities = capabilities,
}

Lspconfig.csharp_ls.setup{
    opts = make_config(),
    on_attach = LspOnAttach,
    capabilities = capabilities,
}

require("conform").setup({
  formatters_by_ft = {
    lua = { "stylua" },
    -- Conform will run multiple formatters sequentially
    python = { "isort", "black" },
    -- Use a sub-list to run only the first available formatter
    javascript = {  "prettierd", "prettier"  },
	cpp = { "clang-format" },
  },
})

vim.api.nvim_create_autocmd("BufWritePre", {
  pattern = "*",
  callback = function(args)
    require("conform").format({ bufnr = args.buf })
  end,
})

require "lsp_signature".setup({
  bind = true, -- This is mandatory, otherwise border config won't get registered.
  handler_opts = {
    border = "rounded"
  }
})
lspconfig.zls.setup{
	root_dir = util.root_pattern("compile_commands.json", "compile_flags.txt", ".git") or vim.loop.os_homedir(),
	opts = make_config(),
	capabilities = capabilities,
    on_attach = LspOnAttach,
}

lspconfig.gopls.setup{
  opts = make_config(),
  capabilities = capabilities,
  cmd = {"gopls"},
  filetypes = {"go", "gomod"},
  root_dir = lspconfig.util.root_pattern("go.work", "go.mod", ".git"),
  settings = {
    gopls = {
      analyses = {
        unusedparams = true,
      },
      staticcheck = true,
    },
  },
}

lspconfig.pyright.setup{
    capabilities = capabilities,
    opts = make_config(),
}

