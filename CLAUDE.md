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
- `<leader>?` (also `<leader>fk`) searches every key binding with its description (telescope keymaps). `?` inside a debugger panel shows the debugger keys.
- Terminal resize / font zoom (`core/autocmds.lua` VimResized): debounced 40 ms; every tab page is equalized without autocmds and the current one kept (`tabdo` left the last tab current). dap-ui panels are `winfixwidth/height`, so `wincmd =` forced a size change onto one panel (stack and REPL down to 2 rows, never back); their layouts are reset to their proportions instead (`debug_ui.relayout`; layout sizes are screen fractions: left 25 %, bottom 20 %).
- Symbol finders (`lua/core/symbols.lua`, Rider's Go to Class / Symbol / File Member): `<leader>fc` class (UEP's class index in UE projects, clangd otherwise), `<leader>fs` function, `<leader>fS` any symbol (clangd `workspace/symbol` asked directly, live, from any buffer; empty for the first ~15 s while clangd loads its index), `<leader>fm` members of the current file.
  - With no C++ file open (an empty Neovim in a project), the search starts the project's clangd without a buffer (`symbols.ensure_clangd`, `vim.lsp.start{attach=false}`). A file opened later joins that client (same name and root).
  - clangd reads the compile database, and loads its index, only when a file asks for its flags. A bufferless clangd answered nothing for 60 s. `symbols.load_index` sends didOpen + didClose of an empty `<root>/.nvim-clangd-index.cpp` (no buffer, nothing written): results 11-14 s after startup on V2. That costs one preamble build, as opening any file would.
  - Unreal outside Windows (`compiledb_unix`) starts this clangd at startup, and loads the index 3 s later if no file was opened.
  - The statusline shows it, since no file reports a state: `⠋ clangd starting`, then `⠋ clangd loading index` until an empty `workspace/symbol` query returns results (`core.clangd.watch_index`; on V2 0 results, then 500 at about 15 s). `⠋ compile db` shows while a generator runs (`core.compiledb` / `ue.compiledb_unix` `busy()`).
  - Outside Windows a UE project shows its name and `▶ <configuration>` (`ue/run.lua`); `UE ✓` comes from the Windows-only plugin suite (`ctx.is_ue`). Telescope's own LSP pickers fail or mix in ue_ls when both servers attach to a buffer.
- Code navigation (`lua/core/code.lua`, keys as in the user's Rider keymap "VSCode copy"): `Alt+Enter` / `Ctrl+.` / `<leader>ca` code actions (clangd fixes such as the missing `#include`); `F2` / `<leader>cr` rename; `F12` definition; `Alt+]` / `Shift+F12` / `Shift+Alt+F12` / `<leader>cu` / `<leader>fu` Find Usages; `Ctrl+F12` / `<leader>cm` implementations and overrides; `Shift+Alt+H` / `<leader>ch` callers, `<leader>cH` callees; `<leader>cb` base classes, `<leader>cd` derived classes. They ask clangd only and open a Telescope picker (a single result jumps). The symbol under the cursor and its uses in the file are highlighted while the cursor rests (documentHighlight); inline parameter-name and type hints are on (`<leader>uh` toggles). Windows Terminal leaves Alt+Enter unbound in this user's settings; Alacritty on Windows binds it to ToggleFullscreen by default (`platform_key_bindings`, 0.16), so the user's `alacritty.toml` sends `\u001B\r` instead. Through tmux (`escape-time 0`) it reaches Neovim as `<M-CR>` (tested with `send-keys M-Enter`). Git: `<leader>gc` changed files, `<leader>gl` log, `<leader>gf` file history, `<leader>gB` branches, `<leader>gL` inline blame, `<leader>gq` all hunks to quickfix.
- `<leader>b` (Build) and `<leader>c` (Code) groups hold generic actions; UE-specific actions (`<leader>U`) are reserved for things only UNL/UEP/UBT can do
- LSP uses Neovim 0.11 native `vim.lsp.config()` + mason-lspconfig v2 `automatic_enable` — NOT the old `lspconfig.X.setup()` pattern
- Completion is blink.cmp (NOT nvim-cmp) with `fuzzy.implementation = "lua"` to avoid Rust dependencies on Windows
- LSP capabilities come from `require('blink.cmp').get_lsp_capabilities()` and must be passed to `vim.lsp.config()`
- Neovim 0.11 built-in keymaps (grn, gra, grr, gri, grt, gO, K, `<C-s>`, [d, ]d, gcc, gc) are intentionally NOT overridden — the config only adds `gd`, `gD`, `<leader>ld`, `<leader>li`, `<M-o>` (switch header/source), `<M-]>` (references)
- LSP progress uses fidget.nvim (top-right spinner), NOT lualine — fidget consumes the progress ring buffer so `vim.lsp.status()` returns empty when active
  - Exception: clangd's background index (`backgroundIndexProgress`, minutes to hours on a UE project) is ignored by fidget and shown in the statusline as `󰒓 index 12% · 14 threads` (`core/clangd.lua` `index_text`, its own LspProgress autocmd). A click shows the project coverage and thread mode.
  - Statusline components must return `%%` for a literal percent sign. A bare `% ` is E539, and after a few failed refreshes lualine stops its timer: the statusline freezes without any message.
- `vim.notify` goes to fidget's notification window (bottom right), not the command line, where a message wider than the screen or with several lines stopped everything at "Press ENTER". `opts.title` becomes fidget's heading. `<leader>un` shows the history.
- `vim.ui.select` is a small Telescope list (`core/ui_select.lua`), not inputlist's "Type number and <Enter>": run configurations, code actions (at the cursor), exception filters, Blueprint values. One Esc cancels, and the caller gets `nil`.
- UNL prints `INFO: Registering and initializing project` at each start: `UNL.cmd.start` is loaded before `UNL.setup()` creates its logger and keeps the fallback logger, which `print()`s. `lang-ue.lua` reloads that module into the same table after setup.
- `lua/core/clangd.lua`:
  - The statusline shows clangd's per-file parse state for the current buffer (`⠋ clangd building preamble`), from the `textDocument/clangd.fileStatus` extension (`init_options.clangdFileStatus`). Without a preamble clangd has no AST: no semantic colors or navigation from that file.
  - In UE projects, once a file is parsed, its header/source counterpart (`switchSourceHeader`) is opened in clangd without a buffer, at most 3 at a time. A UE preamble holds the module's shared PCH engine headers: 270-300 MB, 20-50 s to build per file. With the prewarm, `gd` from a declaration lands on a parsed `.cpp`: semantic colors 6.7 s after the jump instead of 50 s.
  - The prewarm text matches Neovim's (LF line endings, no BOM), so clangd reuses the preamble when Neovim opens the file.
- Discoverability: `F1` (and the clickable `󰌌 F1 keys` in the statusline) opens `lua/core/keyhelp.lua`, one screen of the IDE keys grouped by task. It is made from the real mappings: keys not mapped in the current buffer (LSP keys outside a code file, git hunk keys outside a repo file) are dimmed. While debugging, the Debug section comes first. Its column layout packs sections by height; keep descriptions short (about 34 characters) so three columns fit at 180 columns.
- Layout (`lua/plugins/ui.lua`, `core/options.lua`; checked by rendering the real config through `nvim --embed` at 200, 160, 120 and 100 columns, Windows and WSL):
  - Statusline: left the file (`file_name`: the window under a floating one), git, diagnostics, clangd's state; right the project, `UE ✓`, `▶ <configuration>`, `󰌌 F1 keys`, RAM, file type, position. Encoding and line endings show only when unusual. The file path gets what the other items leave (their widths estimated from their texts; one cell pessimistic in the tests). When it does not fit, RAM, file type and project name give way, then the index progress and the F1 hint (down to the file name); then leading folders shrink to a letter (`S\C\Framework\...`) or give way (`…\GameState\Foo.cpp`), whichever keeps more whole folder names. Neovim's own truncation used to cut the line at the file name.
  - Line numbers: `statuscolumn` puts them right-aligned in one column (with `relativenumber` Neovim put the current line's number at the left edge). Windows without numbers show only signs.
  - which-key: no icon column (it repeated the key as a letter and used emoji the font lacks), `→` between key and description.
  - `Space e` (netrw) without its banner.
  - UE C/C++ indentation (tabs, width 4) also applies in a UE project opened from WSL / Linux / macOS.
- Clicking the line-number/sign gutter of a C/C++ file toggles a breakpoint (`core/keymaps.lua` `<LeftMouse>`); a click in the text is the normal click.
- Debugger toolbar: while a session runs, the tabline is the toolbar (`debug_ui.toolbar`): the state (`󰏤 Paused at a breakpoint in add_points (demo.c:8)`, `▶ Running`), then named, clickable buttons with their keys, only those usable now, then the exception checkboxes when there is room. It shrinks to fit: location first, then long names, then keys. dap-ui's own controls are off: bare icons, two of them (step back, disconnect) unsupported by dbgeng-dap.
- Debugger keys (Rider's VS Code keymap): F5 start/continue, F6 pause, Shift+F5 stop, Ctrl+Shift+F5 restart (UE: builds again), F9 breakpoint, F10/F11/Shift+F11 steps, Ctrl+F10 run to cursor. `Space d` menu entries name their F-key; `Space dw` add to Watches, `Space dL` list / `Space dC` delete all breakpoints, `Space d?` all debugger keys. `debug_ui.M.KEYS` feeds the `?` list and F1; keep it in step with `lang-cpp.lua`.
- Panel titles only offer what the adapter supports (`e edit` in Variables needs `supportsSetVariable`, which dbgeng-dap lacks). Watches: `i` starts typing an expression.
- Tested with `dbgeng-dap` launching a small C program (no Unreal needed): a `launch` config with `program`.
- Debugger UI (`lua/core/debug_ui.lua`, nvim-dap-ui options):
  - Icons and signs are plain Unicode where the terminal font (Cascadia Mono NF) has the symbol, else its Nerd Font icon: `󰏤` for ⏸, `󰒓` for ⚙, `󰌌` for ⌨, `󰅖` for ✗, `󰄲`/`󰄱` checkboxes. Symbols missing from the font fall back to another font in the terminal, which may not keep the cell grid (not checked in the terminal itself). Check a new glyph against `CascadiaMonoNF-Regular.ttf` (fontTools `getBestCmap`).
  - Every panel title starts at the left edge, in line with the panel's text.
  - Every panel has a title with its main keys, as many as the panel width holds (`debug_ui.winbar`; Neovim's `%<` cut them at their start). Breakpoints is the top panel, and its title holds the count and the exception checkboxes (`󰄲 ensure 󰄱 throw 󰄲 AV`); the count gives way first. `?` in any panel lists all debugger keys.
  - A click opens a frame or breakpoint (`<LeftRelease>` element mapping).
  - `<leader>dk`/`<leader>dj` move a frame up/down, `<leader>dT` lists the threads, `<leader>dx` picks exception settings and `<leader>dE` toggles "Suspend on ensure".
  - The settings persist in `stdpath('state')/dap-exceptions.json` and reach new sessions through `dap.defaults.dbgeng.exception_breakpoints`.
- dbgeng-dap exception filter `ensure` (on by default, like Rider's "Suspend on ensure"):
  - A failed `ensure()` breaks in UE's ensure lambda, whose static locals are `ENSURE_Static`/`ENSURE_bExecuted` (`AssertionMacros.h` `UE_ENSURE_IMPL2`).
  - With the filter off, the adapter writes `ensure() failed at File.cpp:N` to the console and continues. With it on, the stop reads "ensure() failed".
  - Per-ensure mute, like Rider: stopped on an ensure, the toolbar shows "Ignore this ensure" (also `<leader>dI`). That ensure's location (top frame file:line) goes to `ignored_ensures` in `dap-exceptions.json` and to the adapter through the custom request `dbgengIgnoreEnsures` (at each session start and on change). The adapter then logs `ensure() failed at File.cpp:N (not suspended: this ensure is ignored)` and continues; other ensures still suspend. `<leader>dx` lists ignored ensures; selecting one brings it back.
  - Frames show the function name (with source) or a short module name (`CoreUObject!UFunction::Invoke`).

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
  - Each Neovim uses the engine native to where it runs; there is never a mix (`ue/run.lua` header, `core/context.lua`):
    - Windows: the above (UBT.nvim, Win64, dbgeng-dap).
    - WSL in a Windows project with no engine installed in WSL for it (`ctx.wsl_ue`): the Windows engine through interop. Windows `UnrealBuildTool.exe <Target> Win64 <Config> -project=<D:/...> -WaitMutex` from `<Engine>/Engine/Source`; the Win64 binaries (the `.uproject` argument as a Windows path); dbgeng-dap run by Windows Python. Tested on V2: build (up to date, 1 s), F5 launched the DebugGame editor, a breakpoint in a UCLASS constructor hit with the stack as `/mnt/d/development/V2/...` and `/mnt/c/Program Files/...`, Shift+F5 ended it.
    - WSL with an engine installed in WSL for the project (`$UE_ENGINE_ROOT`, an EngineAssociation path, or `~/.config/Epic/UnrealEngine/Install.ini`; an engine under `/mnt/` does not count): `ctx.ue_unix` with platform Linux, as on native Linux. Its compile database goes to `Intermediate/ClangDatabase/Linux/`, so the one at the root stays Windows Neovim's. Tested only with a stand-in engine.
    - Linux / macOS (`ctx.ue_unix`): `Engine/Build/BatchFiles/<Linux|Mac>/Build.sh`, `Binaries/Linux/<Name>[-Linux-<Config>]` (macOS: inside `<Name>.app/Contents/MacOS/`), codelldb. Untested with a real engine.
    - Outside Windows the build runs as a job (`stdpath('cache')/ue-build.log`); errors (MSVC and clang formats, Windows paths turned into `/mnt/...` in the project's spelling) go to the quickfix list, `Space be` opens it. The keys are mapped by `ue.run.setup_keys()` (`init.lua`); F5 and Shift+F5 check `ue.run.available()`. The F1 "Build and run" section and dbgeng's ensure keys follow the same checks.
    - Ending the WSL side of a Windows program (SIGTERM) ends the program (tested). The selected configuration is remembered per side (`stdpath('state')` differs).
- dbgeng-dap ends its process (TerminateProcess with code 0) right after its last message, `terminated` or the `disconnect` response. nvim-dap kills the adapter as soon as it reads that message, and the kill exits with code 1, which shows as "adapter exited with 1".
  - From WSL, nvim-dap's SIGINT made WSL's interop process exit 1 whatever Python did, so the adapter runs through `sh -c 'trap "" INT; ...'` (`lang-cpp.lua`); it ends on stdin's EOF.
- dbgeng-dap from WSL (`--wsl`, `--path-map <root as typed>=<win_root>`): `dap.PathMap` turns incoming `path`/`program`/`cwd`/`engineRoot` values and `/`-paths in `args` into Windows paths, and outgoing `path` values into `/mnt/<drive>/...`, with the project root in the spelling used in WSL (no second buffer). Tested with a small MSVC program and with V2.
- dbgeng-dap's deferred source breakpoints are `Module!Function+off`; a function name is used only if it is unique in the image (`LineResolver.name_count`). An overloaded name (every UCLASS constructor has an `FVTableHelper` twin) failed to evaluate when the module loaded, and cdb then stopped the program at that load on every continue (seen on Windows and WSL). Such locations are relative to a uniquely named function, from the same source file when the image has no anchor yet.
- `lua/ue/status.lua` puts UNL's background work in the statusline: `UE ⠋ indexing 42%`, `UE ⠋ scanning`, `UE ✓` (ready) or `UE 󰅖` (server down). Clicking it runs `:UNL status`.
  - Server state comes from `UNL.status`, which polls `simple_status` every 2 s.
  - The percentage comes from UNL's refresh progress events through the global event hook (`UNL.status` already owns the `refresh` category hook).
- `lua/ue/session.lua` restores the project's last files when Neovim starts in a UE project without file arguments (`stdpath('state')/sessions/<project>.vim`). Headless runs never save or restore. Before sourcing, `D:///...` paths (saved before the UNL path fix below) are rewritten to `D:/...`.
- UNL Telescope callback picker is monkey-patched in `lang-ue.lua` to fix prompt buffer crashes on dynamic selection
- UNL's index rebuilds Windows paths as `D:///Development/...` (`scanner/src/db/path.rs` PATH_CTE: Prefix `D:` + RootDir `/` + ...). `lang-ue.lua` rewrites every `UNL.db.remote` result to `D:/...`. Without it, files opened from UEP pickers got buffers named `D:\\\Development\...`: a duplicate of an open file, an LSP URI matching neither `compile_commands.json` nor clangd's index (a 3-minute cold parse), and telescope's previewer hit its 250 ms timeout ("Previewer timed out"; the normal path previews in 1 ms). The server accepts `D:/...` input (`to_db_path_format`).
- `UNL.db.get_file_symbols` is wrapped in `lang-ue.lua` to retry "Project not found"/ECONNREFUSED for up to 10 s. unl-server registers the project a few hundred ms after it starts, and UEA's first lens query used to lose that race: an error plus an ENTER prompt at startup.
- UCM parent picker uses UNL streaming picker (`source.type = 'callback'`) instead of raw `finders.new_table` — the latter breaks at UE-scale datasets (57K+ entries). Entries are priority-sorted: engine base classes (static list) → main game module → plugins → everything else
- `lua/ue/compiledb.lua` keeps clangd's `compile_commands.json` current with no manual step, like Rider. UNL's index (`UE ✓`) is separate and does not feed clangd.
  - It runs UBT GenerateClangDatabase for `preset_target` (Development Editor) when:
    - the database is missing, or older than `*.uproject`, `*.uplugin`, `*.Build.cs` or `*.Target.cs` (checked 1.5 s after startup, with `rg` off the main loop);
    - one of those files is saved;
    - a project `.cpp` newer than the database and missing from it is opened or saved;
    - a class is created with `<leader>Un`, or `<leader>bj` is pressed.
  - UBT generates the database with `-NoPCH` (`GenerateClangDatabase.cs`). Project headers rely on the shared PCH that the real build force-includes, so clangd reported `int32`, `TArray`, `FPaths`... as unknown. Each entry therefore gets the `/FI` PCH line from the module's unity build response file (`Module.*.cpp.obj.rsp`, other configurations as fallback). The same step runs after each successful `ue.run` build, for modules built for the first time.
  - Then the clangd clients restart and the open C++ buffers re-attach.
  - UBT.nvim runs one job at a time, and starting a job stops the running one. Generation waits for a running build, and `ue.run.build` waits for a running generation.
  - The statusline shows `UE ⠋ compile db` meanwhile.
- `ue_ls` (`tools/ue-lsp` in this repo, stdlib Python LSP; override path with `$UE_LSP_PATH`) is configured in `lsp.lua` only in UE projects and only if the script exists: `.ini` section/key/value completion, hover, go-to-definition, diagnostics; C++ specifier/meta hover + diagnostics. Its C++ completion is off (`init_options.cpp.completion = false`) because blink-cmp-unreal provides it. Root detection uses a `root_dir` function because `vim.fs.root` does not accept `*.uproject` globs
- Engine navigation (`lsp.lua`):
  - The engine root comes from the project `compile_commands.json` `directory` field. It is read on use, because the database can appear after startup.
  - The project `clangd` gets `--compile-commands-dir=<project>` and a `root_dir` function. Project files and engine headers attach to it; engine `.cpp` files do not. Without this, Neovim starts an extra flag-less clangd for any engine file, because the engine tree has no root marker.
  - Engine `.cpp` files go to `clangd_engine`, which uses ue-lsp's synthesized `%LOCALAPPDATA%/ue-lsp/cache/engine-cdb` and has no background index.
  - `gd` in UE projects asks clangd first. When clangd returns only header declarations, it uses clangd `textDocument/symbolInfo` plus ue_ls `ue.findImpl` to jump to the out-of-line body; several hits go to quickfix.
- ue_ls memory (V2, UE 5.6; private bytes): about 100 MB, was 155-205 MB.
  - After validating the header index it drops the engine file table (38k headers, ~60 MB of objects; `Indexer.release`). A project header save reloads it from its pickle (~0.1 s) for the derived rebuild.
  - The Blueprint index is built after validation, not alongside it (both read that table). Its periodic refresh shares the previous tables when no asset and no header changed (`BPIndex.build(prev=...)`), and the raw asset records are dropped after attribution. Results were compared old vs new: equal.
  - clangd (~0.9 GB tracked, 1.2-2 GB private) was left as is: the background index (~650 MB) is what Find Usages and symbol search answer from, and fewer threads would slow indexing.
- Blueprint values:
  - ue_ls code lens on UPROPERTY lines in headers. Engine headers attach to ue_ls too, so engine properties show their Blueprint values.
  - `<leader>Ul` runs the lens and `<leader>Uv` lists the values of the property under the cursor. Both open a Telescope picker; `<CR>` copies the asset path.
  - The client-side command handler is `vim.lsp.commands['ue.bpValues']`.
- `core/context.lua` also detects the project from the first file argument (`nvim path/to/Project.uproject` or a file inside a project from another cwd) and then `cd`s to the project root so cwd-based UE tooling works

**Prerequisites:** Rust/Cargo, fd, ripgrep

**Per-project setup:** `.clangd` is auto-created in the UE project root on first open (with `-D__INTELLISENSE__`, suppressed diagnostics, disabled clang-tidy). `Diagnostics.Includes.IgnoreHeader` keeps `CoreMinimal.h` and `*.generated.h` from being reported as unused includes, as in Rider (ReSharper C++ has `IsCoreMinimalFileInclude` / `IsHeaderToolGeneratedFileInclude` checks; seen as names in `JetBrains.ReSharper.Cpp.dll`, behaviour not decompiled). clangd's include cleaner counts a header as used only when a symbol the file uses is declared in that header itself (or one it exports with an IWYU pragma); `CoreMinimal.h` is 148 `#include`s and nothing else, so it was always "not used directly". A second section skips `Intermediate/` (UHT `.gen.cpp`) in the background index: with the shared PCH every indexed file is a full UnrealEd parse (~45 s CPU, about 10 files/min at `-j=8`), and those files only add `Z_Construct_*` noise to symbol search.

`.clangd` also removes `-resource-dir`: UBT's compile database points it at Visual Studio's clang 19 headers, and with those clangd 20's **background index** records every parameter whose type is a template with a default argument (`TArray`, `TMap`, `TSet`, `TSharedPtr`, `std::vector`) as `int`. The symbol IDs then differ from the editor's parse, so Find Usages, implementations and callers of such functions came back empty while the class finders worked. The editor's own parse was not affected. clangd never re-indexes for changed flags, so on startup an index without the marker `.cache/clangd/nvim-index-v2` is moved aside and deleted (before clangd starts; with clangd already running it asks for a restart). While an index is incomplete (flag `.cache/clangd/nvim-index-rebuilding`, written when the index is reset or first built), `lua/ue/clangd_index.lua` picks clangd's threads:
- **No Unreal process running** (any `UnrealEditor*` or a project target exe): 14 threads at normal priority.
- **One running:** 4 threads at background priority. Each indexing thread peaks at about 1.7 GB, and 8 threads next to UnrealEditor DebugGame ran the 31 GB machine out of RAM.

A 15 s `tasklist` poll, and `ue.run` just before it launches something, switch the mode by force-restarting clangd (a busy clangd takes 30 s+ to exit gracefully). The resulting "quit with exit code 1" warning is hidden.

When clangd's `backgroundIndexProgress` ends and at least 98% of the compile-DB files outside `Intermediate/` have a shard, the flag is removed and clangd goes back to 8 background threads.

Measured on 8 V2 files at `-j=8` with RAM free: normal priority 3.3 files/min, background 2.9; with RAM short, background dropped to 1.6.

**Stale generated code (`lua/ue/uht_shadow.lua`):** `GENERATED_BODY()`, `UCLASS()`, `VINTERFACES()` and the dynamic delegate macros expand to `FID_<file>_h_<__LINE__>_<suffix>`, which UHT defines in `X.generated.h` only for the lines of the last build. A line added or removed above them gave clangd errors until the next build: "A type specifier is required for all declarations" on `GENERATED_BODY` and "Call to deleted constructor" on the class (reproduced in WSL and Windows by deleting one include line).
- `Intermediate/ClangdUHT/X.generated.h` (shadow) includes the real header (`// IWYU pragma: export`, or clangd's unused-includes flags the include in `X.h`) and defines those macros for the lines within 80 of each real one, as aliases of the nearest.
- `.clangd` adds `"/clang:-iquote<root>/Intermediate/ClangdUHT"` (a clang-cl argument; `-iquote` folders are searched for `"..."` includes before `/I`). Windows Neovim writes it with the rest of `.clangd`; WSL adds it to a `.clangd` this config wrote and restarts clangd once.
- Shadows are rewritten when the real header is newer: at startup (+3 s), after every `ue.run` build (UHT runs even when the compile fails), on FocusGained (at most every 20 s), and for the entered header (BufEnter). The scan runs as `nvim --clean --headless -l uht_shadow.lua --job <root> <win_root>`: 0.2 s on Windows, ~10 s in WSL (stats over /mnt/d), off the editor loop. A shadow-format change bumps `VERSION` (`.version` in the folder) and rewrites them all.
- Names found in two modules get no shadow. Only the Editor target's Win64 headers are shadowed (what the compile database uses); not for `ctx.ue_unix`.
- Tested on V2 (WSL and Windows): after deleting a line, and after adding two, no diagnostics at `GENERATED_BODY`; two `.cpp` files gave the same `clangd --check` result with and without shadows.

**First-time UE project workflow:**
1. Open Neovim in the UE project root (`.clangd` is auto-created)
2. `compile_commands.json` is generated by itself (`lua/ue/compiledb.lua`, about 10 s); clangd restarts with it
3. UNL server loads and scans project structure (statusline `UE ⠋ indexing N%`)
4. clangd will begin background indexing (first run: hours, subsequent: fast)

## Compile database (clangd) everywhere

clangd needs `compile_commands.json`. Without it, it guesses flags: no include paths, no defines, false errors. Who writes it:
- **Unreal on Windows:** `lua/ue/compiledb.lua` (UBT, see Unreal Engine 5 Support).
- **Unreal elsewhere:** `lua/ue/compiledb_unix.lua`, with the same triggers (missing, older than `*.uproject`/`*.uplugin`/`*.Build.cs`/`*.Target.cs`, those saved, a new `.cpp`) and the same PCH fix. `Space bj` runs it by hand.
  - **WSL in a Windows project** (`ctx.wsl_ue`): Windows `UnrealBuildTool.exe` through WSL interop, run from `<Engine>/Engine/Source` with Windows paths, about 10 s. The result is byte-identical to the Windows-generated database (tested on V2: 1174 entries).
  - **Linux / macOS** (`ctx.ue_unix`): Epic's `Engine/Build/BatchFiles/<Linux|Mac>/Build.sh` (it sets up the bundled dotnet). The engine is found from the database's `directory`, `$UE_ENGINE_ROOT`, the `.uproject` EngineAssociation path, `Install.ini` (`~/.config/Epic/UnrealEngine/` on Linux, `~/Library/Application Support/Epic/UnrealEngine/` on macOS), or `/Users/Shared/Epic Games/UE_<ver>`.
  - The PCH fix on Linux/macOS adds `-include "<SharedPCH header>"`, taken from the module's `Module.*.rsp` (`-include`, or the header of `-include-pch X.h.gch`).
  - Only tested with a stand-in `Build.sh` (no Linux or Mac engine available). The real `.rsp` names and contents on those platforms are unverified.
  - clangd gets `--compile-commands-dir=<project>`, `--header-insertion=never`, `--pch-storage=disk`. The rest of the UE plugin suite stays Windows-only.
- **Other C/C++ projects** (`lua/core/compiledb.lua`, any OS). clangd itself finds `compile_commands.json` or `build/compile_commands.json` in every parent folder (clangd 11+). When neither exists for an opened file:
  - **CMake:** configure with `-DCMAKE_EXPORT_COMPILE_COMMANDS=ON`, automatically, since configuring builds nothing. It goes into the project's existing build folder (a `CMakeCache.txt` of this project in the root or in a build-like folder: `build*`, `_build`, `cmake-build-*`, `out/`, `builddir`), else the first configure preset, else `build/`.
    - Only the Makefile and Ninja generators write the database. Another generator gets a warning; a new `build/` on Windows uses Ninja.
    - Saving `CMakeLists.txt`/`*.cmake` configures again.
  - **Meson:** `meson setup build` (Meson always writes the database), automatically. `meson.build` saves reconfigure.
  - **Make and others:** only a real build shows the commands. A notice says so once. `Space bj` runs `bear -- make -B -k -j<cpus>`, never automatically.
    - On macOS Bear uses its wrapper mode, because SIP blocks preload. Compilers called by absolute path can be missed (Bear docs).
    - `./configure` projects need it run first.
  - A database in a folder clangd does not search reaches it as `initializationOptions.compilationDatabasePath` (`before_init` in `lsp.lua`), so no project file is written.
  - Output of the last run is in `stdpath('cache')/compiledb.log` (UE: `ue-compiledb.log`).
- clangd ignores a database that appears while a file is open until that file is reparsed (tested: still 3 errors after 40 s, 0 after an edit), so every generator restarts the clangd clients (`ue.compiledb.restart_clangd`).
- On macOS clangd gets `--query-driver` for the system, Homebrew and Xcode compilers (system headers, per clangd's system-headers guide). Untested.

## WSL (Ubuntu) and other Linux

The same repository is the WSL config: `~/.config/nvim` in WSL is a clone, updated with `git pull --ff-only /mnt/d/Development/projects/utilities/ed/nvim master` (add `-c safe.directory=...` for the /mnt/d repo). `lazy-lock.json` is gitignored, so each side keeps its own plugin versions.
- WSL runs Neovim 0.13-dev, Windows 0.11. Its newer LuaJIT rejects `goto` as a bare table key (`{ goto = 1 }`); `core/debug_ui.lua` failed to load until it was quoted.
- nvim-treesitter's branch follows the version (`lua/plugins/treesitter.lua`): `main` (the rewrite; `install()` + `vim.treesitter.start`, needs the `tree-sitter` CLI and a C compiler) on 0.12 and newer, the archived `master` on 0.11.
- clangd: the distribution's `clangd` on PATH (Ubuntu clangd 21); Mason is not asked for it on Linux, and `lsp.lua` enables it itself (mason-lspconfig's `automatic_enable` covers only Mason-installed servers).
- codelldb (debugging) is a zip: Mason needs `unzip` (`sudo apt install unzip`); until then it is not requested, so no install error at each start. Installed in WSL (Mason codelldb).
- Debugging outside Unreal (codelldb): F5 → pick "Launch executable" → the prompt offers the program debugged last in this folder (`stdpath('state')/dap-programs.json`), else the newest executable under it; Enter takes it, Esc cancels. codelldb's console is in lldb "commands" mode (`?expr` evaluates); the console title says so. dbgeng's exception checkboxes are shown only in dbgeng sessions.
- Unreal mode (`core/context.lua`, the UE plugin suite) is Windows-only: a `.uproject` folder opened from WSL is a plain C++ project, except for the run configurations (see Unreal Engine 5 Support) and clangd:
  - UBT's `compile_commands.json` is clang-cl + MSVC with `C:/`/`D:/` paths and `.rsp` files. The Linux clangd matched none of it and parsed every file without flags ("clangd fallback" in the LSP log): no UE types, ~20 bogus errors per file.
  - So a Windows UE project under `/mnt/<drive>/` (`ctx.wsl_ue`) gets Windows' Mason `clangd.exe` (`$CLANGD_WINDOWS` overrides) with `--path-mappings`. It reads the engine natively and shares the project's index with Windows Neovim: Find Usages works at once.
  - DrvFs ignores case: `ctx.wsl_ue.win_root` is the real-case Windows path (what the compile database uses), and the first mapping is `<root as typed>=/<win_root>`, so results come back in the spelling of the cwd (`/mnt/d/development/V2`) and do not open a second buffer for the same file.
  - Files inside the Linux file system get no clangd in that mode (Windows clangd cannot read them). Without `compile_commands.json` (generated only by Windows Neovim) the Linux clangd is used.
- Config hot reload watches each folder on Linux (inotify ignores the recursive flag).
- Clipboard: Neovim picks xclip (or win32yank.exe from the Windows Neovim) for `unnamedplus`.

## Hot reload (`lua/core/reload.lua`)

Edits to the live config apply to the running Neovim; no restart. The config folder is watched (libuv `fs_event`, recursive), and changes are applied 300 ms after the last one, so a `git pull` is one reload with one notice listing what was applied. `:ConfigReload` reloads everything by hand.
- `lua/core/*`, `lua/ue/*`: the module is re-required and patched into the already-loaded table, so `local x = require(...)` references get the new functions. A file that fails to load keeps the old module and reports the error.
- After a module reload, its `M.on_reload()` runs, or else its `M.setup()`. Setups must be idempotent: augroups with `clear = true`, named dap listeners.
- Module-local variables start fresh on reload. Keep runtime state that must survive in `M.state`; for example, `debug_ui` keeps "stopped on an ensure" there.
- `core.options` / `core.keymaps` / `core.autocmds` run again.
- `lua/plugins/*.lua`: lazy.nvim re-reads the specs (its own `change_detection` is off: it re-read specs without re-applying them). The changed file's plugins get their keys re-mapped, stale keys are removed, and loaded plugins run `config` again. The dap plugins wait until the debug session ends. lazy copies a plugin's old state, including its cache of resolved keys/opts, onto the new spec; the reloader clears that cache.
- `colors/<name>.lua` is re-applied when it is the current scheme.
- `init.lua` and `core/lazy.lua` need a restart (the notice says so). On Windows libuv also reports file reads; a file not seen before counts as changed only if written after the watcher started. Under `tools/`, dbgeng-dap applies to the next debug session; ue-lsp needs `:LspRestart ue_ls`.
- LSP settings in `lsp.lua` reach running servers only after `:LspRestart`.

## Testing Changes

Open Neovim after editing (or save: hot reload applies it). Useful checks:
- `:Lazy` — plugin install status and errors
- `:checkhealth` — LSP, treesitter, provider diagnostics
- `:Lazy profile` — startup time (target < 50ms)
- `<Space>` then wait — which-key popup should show group labels
