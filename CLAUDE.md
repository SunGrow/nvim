# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A modular Neovim 0.11+ configuration in Lua, managed by lazy.nvim. Runs on Windows (primary), macOS, and Linux.

## Architecture

**Load order** (`init.lua`): `core.keymaps` → `core.options` → `core.autocmds` → `core.lazy`

- `lua/core/` — editor fundamentals (leader key MUST be set before lazy.nvim loads); `context.lua` provides project-type detection
- `lua/plugins/` — one file per plugin concern; lazy.nvim auto-discovers all `*.lua` files in this directory via `require('lazy').setup('plugins')`
- All plugins default to `lazy = true` in `lua/core/lazy.lua`
- `colors/rider-denis-dark.lua` is a colorscheme made from a Rider editor scheme. Its colors are the `.icls` values, with inherited ones taken from Rider's bundled `RiderDark.xml`. clangd semantic tokens (`@lsp.typemod.variable.functionScope`, `@lsp.type.method`, ...) carry ReSharper C++'s identifier colors.
  - The default theme is `catppuccin-latte`. `<leader>uc` opens a theme picker with preview.
  - The last chosen theme is restored from `stdpath('state')/colorscheme` (`lua/plugins/colorscheme.lua`).

**Key design patterns:**
- `lua/core/context.lua` detects project type once at startup (`.uproject` → UE) and caches the result — all files use `require('core.context')` instead of inline `vim.fs.find`
- Context-aware keybindings (`<leader>ff`, `<leader>fg`, `<M-o>`) dispatch to UE-specific or generic backends based on `core.context.is_ue` — same muscle memory everywhere
  - `<leader>ff`/`<leader>fg` first ask UNL's index for components. On a project's first open, UNL builds the index for minutes (V2: 3.5 min), and UEP fails with "No components in DB" and an ENTER prompt. Until the index exists they use plain Telescope.
- `<leader>b` (Build) and `<leader>c` (Code) groups hold generic actions; UE-specific actions (`<leader>U`) are reserved for things only UNL/UEP/UBT can do
- LSP uses Neovim 0.11 native `vim.lsp.config()` + mason-lspconfig v2 `automatic_enable` — NOT the old `lspconfig.X.setup()` pattern
- Completion is blink.cmp (NOT nvim-cmp) with `fuzzy.implementation = "lua"` to avoid Rust dependencies on Windows
- LSP capabilities come from `require('blink.cmp').get_lsp_capabilities()` and must be passed to `vim.lsp.config()`
- Neovim 0.11 built-in keymaps (grn, gra, grr, gri, grt, gO, K, `<C-s>`, [d, ]d, gcc, gc) are intentionally NOT overridden — the config only adds `gd`, `gD`, `<leader>ld`, `<leader>li`, `<M-o>` (switch header/source), `<M-]>` (references)
- LSP progress uses fidget.nvim (top-right spinner), NOT lualine — fidget consumes the progress ring buffer so `vim.lsp.status()` returns empty when active

## Conventions

- Leader key is `<Space>`, with mnemonic groups: `f`=Find, `g`=Git, `l`=LSP, `c`=Code, `b`=Build, `d`=Debug, `U`=Unreal
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

`lua/plugins/lang-ue.lua` provides the taku25 plugin suite with **zero overhead** outside UE projects. All UE specs use `cond = is_ue_project` which checks for a `.uproject` file at startup via `vim.fs.find`.

**How it works:**
- Open Neovim in a UE project directory (containing `.uproject`) → full UE suite loads
- Open Neovim anywhere else → zero UE plugins load, zero memory/startup cost

**Plugin suite (6 UE plugins + 1 integration):**
- UNL (core RPC server), UEP (project explorer), UBT (build tool)
- UCM (class management), UEA (Blueprint/asset tracking + Code Lens), UDB (debug)
- blink-cmp-unreal (UE completion source for blink.cmp)

**Key architectural decisions:**
- Filetype detection (`.uproject`→json, `.ush`/`.usf`→hlsl) is handled inline in `lang-ue.lua` via autocmds
- UE indentation (tabs, width 4) is set via FileType autocmd for c/cpp — `.editorconfig` overrides if present
- UEA uses `ft = { 'cpp', 'c' }` trigger (not just `cmd`) so Code Lens registers before C++ buffers open
- UDB.nvim owns DAP launch config in UE projects — `lang-cpp.lua` skips codelldb setup when `.uproject` is found and instead registers the `dbgeng` adapter (`tools/dbgeng-dap` in this repo, override with `$DBGENG_DAP_PATH`) plus an "Attach to UnrealEditor" config; `lang-ue.lua` sets UDB `adapter_type = 'dbgeng'` when that script exists, else `codelldb`
- `lsp.lua` adjusts clangd flags for UE: `--header-insertion=never`, no `--clang-tidy`, `--pch-storage=disk`
- blink-cmp-unreal extends blink.cmp via lazy.nvim spec merging (`optional = true` + `opts_extend`)
- Run configurations (`lua/ue/run.lua`) are generated the way Rider builds them:
  - One configuration per `Source/*.Target.cs` target and per configuration the engine can build. An installed engine builds DebugGame and Development for the Editor target, plus Shipping for Game targets.
  - They are named like Rider's dropdown: "DebugGame Editor", "DebugGame", "Development Editor", "Development", "Shipping".
  - The same list becomes the UBT presets, so UBT's own dynamic presets (every target × every configuration) are not used.
  - Every run builds first through UBT, then launches.
  - Keys follow Rider's VS Code keymap:
    - F5: debug, or continue in a session
    - Ctrl+F5: run without the debugger
    - Shift+F5: stop
    - Ctrl+Shift+B: build
  - `<leader>bc` (or a click on the `▶` statusline item) chooses the configuration. The choice is remembered per project in `stdpath('state')/ue-run/<project>.json`.
  - UBT's echo and notify logging are off. It logs every compiler warning at WARN, and each long echo raised a hit-enter prompt that stalled the build output and the launch after it. `ue.run` reports one line per build and opens `:UBT diagnostics` when a build fails. The full log is in `stdpath('cache')/UBT/`.
- dbgeng-dap ends its process (TerminateProcess with code 0) right after its last message, `terminated` or the `disconnect` response. nvim-dap kills the adapter as soon as it reads that message, and the kill exits with code 1, which shows as "adapter exited with 1".
- `lua/ue/status.lua` puts UNL's background work in the statusline: `UE ⠋ indexing 42%`, `UE ⠋ scanning`, `UE ✓` (ready) or `UE ✗` (server down). Clicking it runs `:UNL status`.
  - Server state comes from `UNL.status`, which polls `simple_status` every 2 s.
  - The percentage comes from UNL's refresh progress events through the global event hook (`UNL.status` already owns the `refresh` category hook).
- `lua/ue/session.lua` restores the project's last files when Neovim starts in a UE project without file arguments (`stdpath('state')/sessions/<project>.vim`). Headless runs never save or restore.
- UNL Telescope callback picker is monkey-patched in `lang-ue.lua` to fix prompt buffer crashes on dynamic selection
- `UNL.db.get_file_symbols` is wrapped in `lang-ue.lua` to retry "Project not found"/ECONNREFUSED for up to 10 s. unl-server registers the project a few hundred ms after it starts, and UEA's first lens query used to lose that race: an error plus an ENTER prompt at startup.
- UCM parent picker uses UNL streaming picker (`source.type = 'callback'`) instead of raw `finders.new_table` — the latter breaks at UE-scale datasets (57K+ entries). Entries are priority-sorted: engine base classes (static list) → main game module → plugins → everything else
- `<leader>Un` auto-runs `UBT gen_compile_db` after successful class/struct creation via the UCM `on_complete` callback, so clangd immediately picks up new files
- `ue_ls` (`tools/ue-lsp` in this repo, stdlib Python LSP; override path with `$UE_LSP_PATH`) is configured in `lsp.lua` only in UE projects and only if the script exists: `.ini` section/key/value completion, hover, go-to-definition, diagnostics; C++ specifier/meta hover + diagnostics. Its C++ completion is off (`init_options.cpp.completion = false`) because blink-cmp-unreal provides it. Root detection uses a `root_dir` function because `vim.fs.root` does not accept `*.uproject` globs
- Engine navigation (`lsp.lua`):
  - The engine root comes from the project `compile_commands.json` `directory` field.
  - The project `clangd` gets `--compile-commands-dir=<project>` and a `root_dir` function. Project files and engine headers attach to it; engine `.cpp` files do not. Without this, Neovim starts an extra flag-less clangd for any engine file, because the engine tree has no root marker.
  - Engine `.cpp` files go to `clangd_engine`, which uses ue-lsp's synthesized `%LOCALAPPDATA%/ue-lsp/cache/engine-cdb` and has no background index.
  - `gd` in UE projects asks clangd first. When clangd returns only header declarations, it uses clangd `textDocument/symbolInfo` plus ue_ls `ue.findImpl` to jump to the out-of-line body; several hits go to quickfix.
- Blueprint values:
  - ue_ls code lens on UPROPERTY lines in headers. Engine headers attach to ue_ls too, so engine properties show their Blueprint values.
  - `<leader>Ul` runs the lens and `<leader>Uv` lists the values of the property under the cursor. Both open a Telescope picker; `<CR>` copies the asset path.
  - The client-side command handler is `vim.lsp.commands['ue.bpValues']`.
- `core/context.lua` also detects the project from the first file argument (`nvim path/to/Project.uproject` or a file inside a project from another cwd) and then `cd`s to the project root so cwd-based UE tooling works

**Prerequisites:** Rust/Cargo, fd, ripgrep

**Per-project setup:** `.clangd` is auto-created in the UE project root on first open (with `-D__INTELLISENSE__`, suppressed diagnostics, disabled clang-tidy).

**First-time UE project workflow:**
1. Open Neovim in the UE project root (`.clangd` is auto-created)
2. `:UBT gen_compile_db` — generates `compile_commands.json` for clangd
3. UNL server loads and scans project structure
4. clangd will begin background indexing (first run: hours, subsequent: fast)

## Testing Changes

Open Neovim after editing. Useful checks:
- `:Lazy` — plugin install status and errors
- `:checkhealth` — LSP, treesitter, provider diagnostics
- `:Lazy profile` — startup time (target < 50ms)
- `<Space>` then wait — which-key popup should show group labels
