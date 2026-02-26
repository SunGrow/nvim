# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A modular Neovim 0.11+ configuration in Lua, managed by lazy.nvim. Runs on Windows (primary), macOS, and Linux.

## Architecture

**Load order** (`init.lua`): `core.keymaps` → `core.options` → `core.autocmds` → `core.lazy`

- `lua/core/` — editor fundamentals (leader key MUST be set before lazy.nvim loads)
- `lua/plugins/` — one file per plugin concern; lazy.nvim auto-discovers all `*.lua` files in this directory via `require('lazy').setup('plugins')`
- All plugins default to `lazy = true` in `lua/core/lazy.lua`

**Key design patterns:**
- LSP uses Neovim 0.11 native `vim.lsp.config()` + mason-lspconfig v2 `automatic_enable` — NOT the old `lspconfig.X.setup()` pattern
- Completion is blink.cmp (NOT nvim-cmp) with `fuzzy.implementation = "lua"` to avoid Rust dependencies on Windows
- LSP capabilities come from `require('blink.cmp').get_lsp_capabilities()` and must be passed to `vim.lsp.config()`
- Neovim 0.11 built-in keymaps (grn, gra, grr, gri, grt, gO, K, `<C-s>`, [d, ]d, gcc, gc) are intentionally NOT overridden — the config only adds `gd`, `gD`, `<leader>ld`, `<leader>li`

## Conventions

- Leader key is `<Space>`, with mnemonic groups: `f`=Find, `g`=Git, `l`=LSP, `c`=Code, `d`=Debug, `U`=Unreal
- Every keymap must have a `desc` parameter for which-key discoverability
- Plugin files return a table (single spec) or list of tables (multiple specs)
- Language-specific bundles live in `lua/plugins/lang-*.lua` modules (e.g., `lang-cpp.lua`, `lang-ue.lua`)

## Adding a New Plugin

Create `lua/plugins/<name>.lua` returning a lazy.nvim spec. Use lazy-loading triggers (`event`, `cmd`, `keys`, `ft`). No changes to other files needed.

## Adding a New LSP Server

1. Add to `ensure_installed` in `lua/plugins/lsp.lua`
2. Optionally call `vim.lsp.config('server_name', { capabilities = capabilities, ... })` in the same file
3. mason-lspconfig `automatic_enable` handles the rest

## Unreal Engine 5 Support

`lua/plugins/lang-ue.lua` provides the full taku25 UnrealDev.nvim suite with **zero overhead** outside UE projects. All UE plugins use `cond = is_ue_project` which checks for a `.uproject` file at startup via `vim.fs.find`.

**How it works:**
- Open Neovim in a UE project directory (containing `.uproject`) → full UE suite loads
- Open Neovim anywhere else → zero UE plugins load, zero memory/startup cost

**Prerequisites:** Rust/Cargo, fd, ripgrep (already present)

**Per-project setup:** Each UE project root needs a `.clangd` file:
```yaml
CompileFlags:
  Add: [-D__INTELLISENSE__, -Wno-everything]
  Remove: [/Yu*, /Yc*, /FI*, /Fp*, -include-pch, -include]
Diagnostics:
  Suppress: [pp_file_not_found, drv_unknown_argument, unknown_argument]
  ClangTidy:
    Remove: ['*']
InlayHints:
  Enabled: Yes
  ParameterNames: Yes
  DeducedTypes: Yes
```

**First-time UE project workflow:**
1. Open Neovim in the UE project root
2. `:UBT gen_compile_db` — generates `compile_commands.json` for clangd
3. `:UEP refresh` — scans project structure
4. clangd will begin background indexing (first run: hours, subsequent: fast)

## Testing Changes

Open Neovim after editing. Useful checks:
- `:Lazy` — plugin install status and errors
- `:checkhealth` — LSP, treesitter, provider diagnostics
- `:Lazy profile` — startup time (target < 50ms)
- `<Space>` then wait — which-key popup should show group labels
