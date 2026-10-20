# ue-lsp

Editor-agnostic (stdio) language server for Unreal Engine projects. Python 3 stdlib only.

* **INI** (`Config/*.ini`): completion of section headers (every config class from engine, engine
  plugins, project, project plugins + sections seen in indexed ini files), keys (class + inherited
  `config`/`globalconfig` properties, `ConsoleVariable` cvar names, keys seen in Base/Default ini),
  values (bool, UENUM names with UMETA DisplayName, numeric values for cvar-mapped enums,
  previously seen values, struct members inside `(A=1,B=…)`). Hover (C++ type, doc comment,
  file:line, value chain from indexed ini files), go-to-definition (section → UCLASS, key →
  UPROPERTY, fallback to first ini occurrence), diagnostics (unknown key in class-backed section:
  warning; unknown section: hint).
* **C++**: inside `UPROPERTY( UFUNCTION( UCLASS( USTRUCT( UENUM( UINTERFACE( UPARAM( UMETA( UDELEGATE(`
  completion of specifiers accepted by UHT (table chain from `EpicGames.UHT`) with docs from
  `ObjectMacros.h`; inside `meta=( … )` the `UM` meta keys valid for that macro; hover docs;
  unknown-specifier warnings. Multi-line arguments and nested parentheses are handled.
* **Blueprint/asset values** (`bpvalues.py`, `uasset.py`): reads `.uasset`/`.umap` tagged properties
  (editor packages, no editor needed). Covers Blueprint CDO overrides, component templates
  (`*_GEN_VARIABLE`, inheritable component handler) and DataAsset instances. Values are attributed
  to the C++ class that declares the property. In headers, a UPROPERTY line gets a code lens
  ("3 BP values" or "BP: BP_Foo = 150") and a hover table. `workspace/executeCommand`
  `ue.bpValues {class, prop}` and `ue.bpValuesAt {uri, line}` return the rows. The index is built
  in the background after startup. Warm rebuilds rescan only changed assets (about 1.5 s for 25k
  packages), and are triggered by lens requests at most every `blueprints.refreshSeconds`.
  CLI: `python -I tools/bpdump.py <asset>` / `--index <project>` / `--query <project> <Class> <Prop>`.
* **Engine `.cpp` navigation**:
  * `enginecdb.py` synthesizes a compile database for every engine and engine-plugin module of the
    editor target, from UBT `-Mode=JsonExport` plus the project's build output. It is written to
    `<cache>/engine-cdb/compile_commands.json` and generated in the background at startup when
    missing or stale. CLI: `--gen-engine-cdb`. A second clangd uses it for engine `.cpp` files only,
    with no background index.
  * `enginenav.py` implements `ue.findImpl {uri, line, name, container}`. It finds out-of-line
    definitions in the module that owns the declaration (nearest `*.Build.cs`), using a lazily built,
    disk-cached per-module definition table: about 0.9 s cold for the Engine module (1,609 files),
    then about 0.02 s.

## Run

```
python <nvim-config>/tools/ue-lsp/ue-lsp.py          # stdio server
python -m ue_lsp                                                      # same, with ue-lsp on PYTHONPATH / as cwd
python ue-lsp.py --index D:/Projects/MyGame                           # build/validate the cache from a shell
```

Engine lookup: `initializationOptions.enginePath` → env `UE_ENGINE_PATH` → `HKLM\SOFTWARE\EpicGames\Unreal Engine\<assoc>`
→ `HKCU\Software\Epic Games\Unreal Engine\Builds` → `%PROGRAMDATA%\Epic\UnrealEngineLauncher\LauncherInstalled.dat`
(`AppName == "UE_<assoc>"`) → ancestor directories of the project.

Cache: `%LOCALAPPDATA%\ue-lsp\cache` (override with env `UE_LSP_CACHE_DIR`). The server writes nothing to
the engine or project trees itself. Generating the engine compile DB runs UBT, and UBT writes its usual
run records and caches (`Engine/Intermediate/UbtRuns`, `Engine/Saved/UnrealBuildTool`), as any build does.
Disable it with `engineCdb = false`.

### initializationOptions

```json
{
  "enginePath": "D:/UnrealEngine/UE_5.8",
  "cpp": { "completion": true, "hover": true, "diagnostics": true },
  "ini": { "completion": true, "diagnostics": true },
  "validateCache": true,
  "indexWaitSeconds": 2.0,
  "engineCdb": true,
  "blueprints": { "enabled": true, "codeLens": true, "hover": true, "refreshSeconds": 60 }
}
```

Set `cpp.completion = false` to leave plain specifier completion to blink-cmp-unreal and keep only
hover/diagnostics from this server.

## Neovim 0.11

`root_markers` in 0.11 is passed to `vim.fs.root()`, whose string markers are exact base names
(`runtime/lua/vim/fs.lua`: "paths and globs are not supported"), so `'*.uproject'` would not match.
Use a `root_dir` function with a function marker instead:

```lua
vim.lsp.config('ue_ls', {
  cmd = { 'python', '<nvim-config>/tools/ue-lsp/ue-lsp.py' },
  filetypes = { 'dosini', 'cpp' },
  root_dir = function(bufnr, on_dir)
    local root = vim.fs.root(bufnr, function(name) return name:match('%.uproject$') ~= nil end)
    if root then on_dir(root) end   -- only attach inside Unreal projects
  end,
  init_options = {
    cpp = { completion = false },   -- blink-cmp-unreal already completes specifier names
  },
})
vim.lsp.enable('ue_ls')
```

Unreal `.ini` files open as `dosini` by default. The server also attaches to `cpp`. Other C++
servers like clangd keep working alongside it.

## Zed (not tested)

Zed only starts language servers that an extension registers. A small extension must declare a
`ue-lsp` language server for the `INI` and `C++` languages and return the command
`python <path>/ue-lsp.py`. Then in `settings.json`:

```json
"languages": { "INI": { "language_servers": ["ue-lsp", "..."] }, "C++": { "language_servers": ["clangd", "ue-lsp", "..."] } },
"lsp": { "ue-lsp": { "initialization_options": { "cpp": { "completion": true } } } }
```

## Tests

```
cd <nvim-config>/tools/ue-lsp
python -m unittest discover -s tests -p "test_units.py" -v
python tests/test_e2e.py
```

Both read the engine (`UE_ENGINE_ROOT`, default `D:/UnrealEngine/UE_5.8`) and a project (`UE_PROJECT_DIR`,
required; skipped without it) read-only. The e2e test uses a temporary cache, so its first phase is a real cold build.

## Known limits

* Header parsing uses regex and brace matching, not a C++ parser. Macros hidden behind `#if`, or
  generated by other macros, can be missed.
* Section names are `/Script/<Module>.<ClassWithoutPrefix>`, or a literal `OverrideConfigSection`
  `TEXT("…")`. `[SectionNameRemap]` in ConfigRedirects.ini and per-object-config sections
  (`[Name Class]`) are not modelled. Per-object sections are never flagged.
* Keys with a `.` in sections whose class has `ConsoleVariable` properties are never flagged (cvar sections).
* The value chain lists occurrences from all indexed ini files in Base → plugin → project order.
  It does not merge per platform or per hierarchy.
* Blueprint values have these gaps:
  * Native-serialized structs without a reader show as `<unparsed …>`: PerPlatform*, FrameNumber,
    MovieScene channels, InstancedStruct, Spline.
  * 139 packages in the legacy UE5 tag format are only partly read.
  * Widget-tree widgets and placed level actors (`.umap`, off by default) are not indexed.
* `ue.findImpl` matches definitions textually. A definition produced by a macro, or one in another
  module than its declaration, is not found. Find-references inside engine `.cpp` is not available,
  because engine TUs are not background-indexed.
* The engine compile DB is one per machine (`engine-cdb/`). Opening another project regenerates it,
  which takes about 10–90 s.
