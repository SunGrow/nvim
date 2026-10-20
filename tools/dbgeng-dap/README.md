# dbgeng-dap

A Debug Adapter Protocol (DAP) server that drives Microsoft's console debugger **cdb.exe** (DbgEng, the
WinDbg engine). It lets Neovim (nvim-dap), and later Zed, debug Unreal Engine C++ on Windows with natvis
(`Unreal.natvis`) and PDB symbols. It needs Python 3.10+ (tested on 3.14), uses only the standard library, and
has no install step.

```
nvim-dap ──DAP (stdio | TCP)──> dbgeng-dap (Python) ──stdin/stdout──> cdb.exe ──DbgEng──> UnrealEditor.exe
                                    │ ctypes
                                    └─ dbghelp.dll: file:line -> addresses (PDB line tables)
```

## Requirements

- cdb.exe from the WinDbg package (`winget install Microsoft.WinDbg`) or the Windows SDK *Debugging Tools*.
  The adapter finds it automatically: first the WinDbg package root in the AppModel registry, then
  `Get-AppxPackage Microsoft.WinDbg`, then `Windows Kits\10\Debuggers\x64`. To use a different cdb.exe, set
  `cdbPath`.
- PDBs next to the binaries. That's the normal layout for UE builds and installed engines.

## Running

```
python <nvim-config>\tools\dbgeng-dap\dbgeng-dap.py              # DAP on stdio
python <nvim-config>\tools\dbgeng-dap\dbgeng-dap.py --port 4711  # DAP on 127.0.0.1:4711, one session
       ... --log C:\Temp\dbgeng-dap.log        # protocol + full cdb transcript (or env DBGENG_DAP_LOG)
```

## nvim-dap configuration

Put this in your own config. This repository doesn't edit `ed/nvim`.

```lua
local dap = require('dap')
local ADAPTER = '<nvim-config>/tools/dbgeng-dap/dbgeng-dap.py'
local ENGINE  = 'D:/UnrealEngine/UE_5.8'          -- engine root (installed or source build)

dap.adapters.dbgeng = {
  type = 'executable',
  command = 'python',
  args = { '-I', ADAPTER },                      -- add '--log', 'C:/Temp/dbgeng-dap.log' when debugging the adapter
  options = { detached = false },
}
-- TCP variant: dap.adapters.dbgeng = { type = 'server', port = '${port}',
--   executable = { command = 'python', args = { '-I', ADAPTER, '--port', '${port}' } } }

local function uproject()
  local f = vim.fn.glob(vim.fn.getcwd() .. '/*.uproject', false, true)[1]
  return f and vim.fs.normalize(f) or vim.fn.input('uproject: ', vim.fn.getcwd() .. '/', 'file')
end

dap.configurations.cpp = {
  {
    name = 'UE Editor (Development)',
    type = 'dbgeng', request = 'launch',
    program = ENGINE .. '/Engine/Binaries/Win64/UnrealEditor.exe',
    args = function() return { uproject() } end,
    cwd = ENGINE .. '/Engine/Binaries/Win64',
    -- natvis: Unreal.natvis is added automatically for programs under <engine>/Engine/Binaries
    -- natvis = { 'D:/path/extra.natvis' },
    -- symbolPath = 'D:/MyGame/Binaries/Win64;' .. ENGINE .. '/Engine/Binaries/Win64',   -- default: exe dir + <uproject>/Binaries/Win64
    stopOnEntry = false,
  },
  {
    name = 'UE Editor (DebugGame)',
    type = 'dbgeng', request = 'launch',
    program = ENGINE .. '/Engine/Binaries/Win64/UnrealEditor-Win64-DebugGame.exe',
    args = function() return { uproject() } end,
    cwd = ENGINE .. '/Engine/Binaries/Win64',
  },
  {
    name = 'UE Game (-game, Development)',
    type = 'dbgeng', request = 'launch',
    program = ENGINE .. '/Engine/Binaries/Win64/UnrealEditor.exe',
    args = function() return { uproject(), '-game', '-windowed', '-ResX=1280', '-ResY=720' } end,
    cwd = ENGINE .. '/Engine/Binaries/Win64',
  },
  {
    name = 'Attach to UnrealEditor',
    type = 'dbgeng', request = 'attach',
    processId = function() return require('dap.utils').pick_process({ filter = 'UnrealEditor' }) end,
  },
}
dap.configurations.c = dap.configurations.cpp
```

`UnrealEditor-Win64-DebugGame.exe` exists only if you build the editor target in DebugGame. If you don't,
run the Development editor; the adapter sets breakpoints in both `UnrealEditor-<Module>.dll` and
`UnrealEditor-<Module>-Win64-DebugGame.dll` whenever both exist, so either one works.

### Launch and attach options

| key | meaning |
| --- | --- |
| `program`, `args` (list or string), `cwd`, `env` | the debuggee (launch only) |
| `processId` | attach target (attach only); on disconnect the adapter detaches (`qd`) |
| `stopOnEntry` | stop at the initial loader breakpoint |
| `symbolPath` | cdb `-y` (default: program dir + `<uproject dir>/Binaries/Win64`; no symbol server, so it works offline) |
| `natvis` | extra `.natvis` files for `.nvload`; `autoNatvis: false` disables the automatic Unreal.natvis |
| `cdbPath` | path to cdb.exe |
| `initCommands` | raw cdb commands to run after startup (for example `.srcpath`, `sxe ld:foo.dll`) |
| `sourceMap` | `{ "D:/build/++UE5/Sync": "D:/UnrealEngine/UE_5.8" }`. Stack frames from installed engines also map automatically through `<engine>\Engine\...` |
| `engineRoot` | overrides engine-root detection (default: the part of `program` before `\Engine\Binaries\`) |
| `breakpointImages` | extra glob(s) of DLL/EXE files to search for source breakpoints |
| `inlineFrames` | `true` turns DbgEng inline-frame debugging back on (default off, see below) |
| `verbose` | forwards ModLoad lines and symbol-loader noise as output |

## How it works

- **cdb driver**: cdb reads its next command only after it prints its prompt (`0:000> `), so the driver writes
  one command, waits for the prompt and returns the text in between. `g`/`p`/`t`/`gu` switch to run mode.
  Output is streamed line by line as DAP `output` events (rate-limited, ModLoad and symbol noise filtered).
  The next prompt means the target stopped, and `.lastevent` + `r $tid` give the reason and thread.
- **Source breakpoints**: cdb's own ``bp `file:line` `` fails with "Ambiguous symbol" whenever a line has
  several code ranges (loops, inlining, lambdas). So the adapter opens the candidate image itself with
  dbghelp (ctypes, a private `SymInitialize` session at a fake base), enumerates every line record of the source
  file (`SymEnumSourceLinesW`) and takes all RVAs of the first line at or after the requested one.
  Installed engine PDBs contain build-machine paths (`D:\build\++UE5\Sync\...`). For those it falls back to a
  file-name match and keeps the PDB path with the longest common path suffix.
  Candidate images for `<root>/Source/<...>/<Module>/x.cpp` are `<root>/Binaries/Win64/*-<Module>*.dll`
  (project, plugin and engine modules), plus the program itself.
  Each address becomes a deferred `bu<id> [/w "cond"] Module!Function+0xoff`, which DbgEng binds when the DLL
  loads. Names that MASM cannot parse (lambdas, templates) are written relative to another function of the
  same image. A bare `Module+0xrva` is avoided because DbgEng re-evaluates it as an unqualified symbol on
  every module load.
  `verified` comes from `bl`. When a `ModLoad:` line for the image appears, the adapter sends a
  `breakpoint` changed event (verified=true).
  Breakpoints changed while the game runs go through a silent break-in (DebugBreakProcess), get applied, and
  the game resumes.
- **Inline frames are off by default** (`.inline 0`). With inline frames on, a line breakpoint in UE code
  usually stops inside an inlined header function (`TArray::begin`, `IsValid`...). Conditions then evaluate in
  that frame and fail ("Unable to bind name"), and `p` steps through header lines. With `.inline 0`, the top
  frame is the function that owns the line, `/w` conditions see its locals, and `p` steps whole source lines
  of that function, like Visual Studio's step-over.
- **Variables**: `dx -r1 <expr>` with natvis. Its indented text output (`name : value [Type: T]`) is parsed
  one level at a time, and each expandable child gets a `variablesReference` holding a dx expression:
  - field: `parent.f` or `parent->f`
  - base class: `(*(Base*)&parent),nd`
  - raw view: `parent,!`
  - container items and natvis synthetic items (`[Pairs]`, `[0x3]` of a sparse set): `@$dapkid(parent, "name", ordinal)`. `dapkid` is a small JsProvider function (`dbgeng_dap/dap_helper.js`, loaded with `.scriptload`) that returns the child from the data-model object, so dx expands it with natvis like any other expression.
  Locals come from `@$curframe.LocalVariables` / `.Parameters`, and registers from `r`.
- **Evaluate**:
  - `hover`/`watch`: an expression whose root identifier isn't a local, a parameter or a member of `this` fails at once. Otherwise DbgEng spends 4-10 s searching every module's symbols before it gives up. Members are rewritten to `this->member`.
  - `repl`: an expression goes to dx. A leading `` ` `` passes the rest through as a raw cdb command, and so does a leading `.` or `!` (`` `kn ``, `.lastevent`, `!peb`). Execution commands (`g`, `p`, `t`, `gu`...) run as resumes. `q`, `.call`, `.detach`, `.attach` and `.create` are refused.
- **Pause**: `kernel32!DebugBreakProcess(pid)`. The stop is reported on the main thread (thread `~0`), not on
  the injected break-in thread. A break-in that loses the race against a real event is swallowed later.
- **Exceptions**: game `__debugbreak`/`ensure` (0x80000003) and second-chance exceptions stop with reason
  `exception`. The filters are `cpp_throw` (`sxe eh`, default off) and `av` (first-chance access violation,
  default on).
- **Disconnect**: a launched target is terminated (TerminateProcess if it is running, then `q`), and an
  attached one is detached (`qd`). cdb is killed if it does not exit.

## DAP coverage

Implemented:

- Requests: initialize, launch, attach, configurationDone, setBreakpoints (condition, hitCondition), setFunctionBreakpoints (`Module!Function`; deferred), setExceptionBreakpoints, threads, stackTrace, scopes (Locals, Registers), variables (lazy, natvis), evaluate (hover/watch/repl), continue, next, stepIn, stepOut, pause, disconnect, terminate.
- Events: initialized, stopped (entry/breakpoint/function breakpoint/step/exception/pause), continued (after repl resumes), output (console/stdout), breakpoint (changed), exited, terminated.

Not implemented: setVariable, logpoints, data breakpoints, disassemble, modules/loadedSources, exceptionInfo,
restart, stepBack, goto, completions.

## Known limitations

- **No function calls in expressions.** dx cannot call native functions (`this->GetName()` returns
  `Error 0x80004005`), and `.call` crashed the debuggee during testing, so the adapter blocks it. Use natvis
  fields instead (`FName` and `FString` display depend on the Unreal.natvis intrinsics DbgEng supports).
- Inline frames don't appear in stack traces by default (`inlineFrames: true` brings them back, without the
  smart stepping). Step-in doesn't enter force-inlined functions.
- The first stop in a module triggers DbgEng's PDB load. That's about 0.8 s for a game module, and seconds
  for `UnrealEditor-Engine.pdb` (544 MB), which the first full stack walk needs.
- An unknown identifier typed into the REPL still costs DbgEng's 4-10 s global symbol search.
- Live Coding patch DLLs (`*-0001.dll`) aren't scanned for source breakpoints.
- nvim-dap ends an `executable` adapter itself right after the `terminated` event (it closes stdin, then
  `handle:kill("sigint")`, `nvim-dap/lua/dap/session.lua` around line 1552), so on Windows it may report
  "command `python` of adapter `dbgeng` exited with 1". cdb has already been told to quit by then, so this is harmless.
- Debuggee console output isn't captured. UE logs arrive through OutputDebugString while a debugger is
  attached, so they still show up as `stdout` output events.

## Tests

```
python -I tests/test_parsers.py      # parsers against real captured cdb output (tests/samples)
nvim --headless --clean -l tests/nvim_smoke.lua <nvim-dap dir> <log> <program> [args]   # nvim-dap smoke test
```
