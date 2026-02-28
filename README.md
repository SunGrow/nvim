# Neovim Configuration

A performance-first, extensible Neovim configuration built on Neovim 0.11+ with lazy.nvim.

## Philosophy

1. **Built-in first** — leverages Neovim 0.11 native LSP keymaps, commenting, snippets, and diagnostics before reaching for plugins
2. **Lazy everything** — all plugins lazy-loaded; startup target < 50ms
3. **Modular** — one file per concern in `lua/plugins/`; add/remove features by adding/removing files
4. **Discoverable** — which-key.nvim popup shows available keybindings as you type
5. **Minimal dependencies** — core config is ~14 plugins; language modules load on demand
6. **Zero overhead** — language-specific features (UE5, C++ debugging) only load when relevant project files are detected

## Prerequisites

| Dependency | Required | Purpose |
|------------|----------|---------|
| [Neovim](https://neovim.io/) 0.11+ | yes | Editor |
| [Git](https://git-scm.com/) | yes | Plugin installation |
| [Nerd Font](https://www.nerdfonts.com/) | yes | Icons (devicons, lualine, which-key) |
| [ripgrep](https://github.com/BurntSushi/ripgrep) | yes | Telescope live grep |
| [make](https://www.gnu.org/software/make/) | optional | Builds telescope-fzf-native for faster sorting |
| C compiler (gcc/clang) | optional | Treesitter parser compilation |
| [fd](https://github.com/sharkdp/fd) | UE5 only | UEP.nvim project file scanning |
| [Rust/Cargo](https://rustup.rs/) | UE5 only | UNL.nvim native scanner build |
| [LLVM/clang-format](https://llvm.org/) | C++ only | C/C++ code formatting |

### Windows (scoop)

```powershell
scoop install neovim git ripgrep make
scoop bucket add nerd-fonts
scoop install JetBrainsMono-NF
# For C++ / UE5 development (optional):
scoop install llvm fd rustup
rustup default stable
```

### Windows (winget)

```powershell
winget install Neovim.Neovim Git.Git BurntSushi.ripgrep.MSVC GnuWin32.Make
```

Install a Nerd Font manually from [nerdfonts.com](https://www.nerdfonts.com/font-downloads).

### macOS (Homebrew)

```bash
brew install neovim git ripgrep make
brew install --cask font-jetbrains-mono-nerd-font
```

### Arch Linux

```bash
sudo pacman -S neovim git ripgrep make base-devel ttf-jetbrains-mono-nerd
```

### Ubuntu / Debian

```bash
# Neovim 0.11+ is not in default repos — use the PPA or download from GitHub releases
sudo add-apt-repository ppa:neovim-ppa/unstable
sudo apt update
sudo apt install neovim git ripgrep make build-essential

# Nerd Font (manual install)
mkdir -p ~/.local/share/fonts
cd ~/.local/share/fonts
curl -fLO https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz
tar -xf JetBrainsMono.tar.xz
fc-cache -fv
```

## Directory Structure

```
nvim/
├── init.lua                  Entry point (4 lines)
├── lua/
│   ├── core/
│   │   ├── options.lua       Editor settings (vim.opt)
│   │   ├── keymaps.lua       Leader key + general keymaps
│   │   ├── autocmds.lua      Autocommands
│   │   └── lazy.lua          Plugin manager bootstrap
│   └── plugins/
│       ├── colorscheme.lua   catppuccin theme
│       ├── treesitter.lua    Syntax highlighting + folding
│       ├── ui.lua            lualine + fidget + which-key
│       ├── editor.lua        hardtime (habit training)
│       ├── telescope.lua     Fuzzy finder
│       ├── lsp.lua           LSP + mason + lazydev
│       ├── completion.lua    blink.cmp
│       ├── formatting.lua    conform.nvim
│       ├── git.lua           gitsigns
│       ├── lang-cpp.lua      C++ DAP (nvim-dap + codelldb)
│       └── lang-ue.lua       Unreal Engine 5 (taku25 suite, conditional)
└── README.md
```

## Plugins

| Plugin | Purpose |
|--------|---------|
| [lazy.nvim](https://github.com/folke/lazy.nvim) | Plugin manager |
| [catppuccin](https://github.com/catppuccin/nvim) | Color scheme |
| [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) | Syntax highlighting, folding |
| [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) | Fuzzy finder |
| [mason.nvim](https://github.com/mason-org/mason.nvim) | LSP/tool installer |
| [mason-lspconfig.nvim](https://github.com/mason-org/mason-lspconfig.nvim) | Auto-enable LSP servers |
| [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) | LSP config presets |
| [blink.cmp](https://github.com/saghen/blink.cmp) | Autocompletion |
| [lazydev.nvim](https://github.com/folke/lazydev.nvim) | Neovim Lua API completions |
| [conform.nvim](https://github.com/stevearc/conform.nvim) | Code formatting |
| [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) | Git gutter signs |
| [lualine.nvim](https://github.com/nvim-lualine/lualine.nvim) | Status line |
| [which-key.nvim](https://github.com/folke/which-key.nvim) | Keymap popup |
| [hardtime.nvim](https://github.com/m4xshen/hardtime.nvim) | Vim motion training |
| [fidget.nvim](https://github.com/j-hui/fidget.nvim) | LSP progress spinner |
| [nvim-dap](https://github.com/mfussenegger/nvim-dap) | Debug Adapter Protocol client |
| [nvim-dap-ui](https://github.com/rcarriga/nvim-dap-ui) | Debug UI (watches, breakpoints, stack) |
| [mason-nvim-dap](https://github.com/jay-babu/mason-nvim-dap.nvim) | DAP adapter installer |

### Unreal Engine 5 (conditional — loaded only in UE projects)

| Plugin | Purpose |
|--------|---------|
| [UNL.nvim](https://github.com/taku25/UNL.nvim) | Core library (Rust scanner, RPC server) |
| [UEP.nvim](https://github.com/taku25/UEP.nvim) | Project navigation, symbol browsing |
| [UBT.nvim](https://github.com/taku25/UBT.nvim) | Build, compile_commands.json, UHT |
| [UCM.nvim](https://github.com/taku25/UCM.nvim) | Class creation, header/source switching |
| [UEA.nvim](https://github.com/taku25/UEA.nvim) | Blueprint/asset tracking, Code Lens |
| [UDB.nvim](https://github.com/taku25/UDB.nvim) | Debug integration (wraps nvim-dap for UE) |
| [blink-cmp-unreal](https://github.com/taku25/blink-cmp-unreal) | UE completion source for blink.cmp |

## Keybindings

Leader key: `Space`

### General

| Key | Mode | Action |
|-----|------|--------|
| `<Esc>` | n | Clear search highlight |
| `<Space>w` | n | Window mode (followed by split commands) |
| `<Space>e` | n | File explorer (netrw) |
| `<Space>s` | n | Save file |
| `<Space>ut` | n | Toggle light/dark theme |
| `Shift+H` | n | Previous buffer |
| `Shift+L` | n | Next buffer |
| `Ctrl+D` | n | Scroll down (centered) |
| `Ctrl+U` | n | Scroll up (centered) |
| `J` | v | Move selection down |
| `K` | v | Move selection up |

### Find (telescope) — `<Space>f`

| Key | Action |
|-----|--------|
| `<Space>ff` | Find files |
| `<Space>fg` | Live grep (search in files) |
| `<Space>fb` | Open buffers |
| `<Space>fh` | Help tags |
| `<Space>fd` | Diagnostics |
| `<Space>fr` | Resume last picker |
| `<Space>fo` | Recent files |
| `<Space>fw` | Grep word under cursor |

### LSP — Built-in Neovim 0.11

These are **built-in Neovim defaults** — no configuration needed. They work automatically when an LSP server is attached.

| Key | Mode | Action |
|-----|------|--------|
| `grn` | n | Rename symbol |
| `gra` | n, v | Code action |
| `grr` | n | Find references |
| `gri` | n | Go to implementation |
| `grt` | n | Go to type definition |
| `gO` | n | Document symbols |
| `K` | n | Hover documentation |
| `Ctrl+S` | i, s | Signature help |
| `Ctrl+]` | n | Go to definition (via tagfunc) |
| `gq` | n, v | Format with LSP (via formatexpr) |

Custom LSP keymaps (added by this config):

| Key | Action |
|-----|--------|
| `gd` | Go to definition (overrides native local-declaration search) |
| `gD` | Go to declaration |
| `<Space>ld` | Show diagnostic float |
| `<Space>li` | LSP info |
| `<Space>lh` | Switch header/source (C/C++ only, via clangd) |

### Diagnostics — Built-in Neovim 0.11

| Key | Mode | Action |
|-----|------|--------|
| `[d` / `]d` | n | Previous / next diagnostic |
| `[D` / `]D` | n | First / last diagnostic |
| `Ctrl+W d` | n | Show diagnostic float at cursor |

### Navigation — Built-in Neovim 0.11

These vim-unimpaired-style mappings are built-in defaults.

| Key | Action |
|-----|--------|
| `[b` / `]b` | Previous / next buffer |
| `[q` / `]q` | Previous / next quickfix item |
| `[l` / `]l` | Previous / next location list item |
| `[<Space>` / `]<Space>` | Add blank line above / below cursor |

### Git — `<Space>g`

| Key | Action |
|-----|--------|
| `]h` / `[h` | Next / previous hunk |
| `<Space>gs` | Stage hunk |
| `<Space>gr` | Reset hunk |
| `<Space>gp` | Preview hunk |
| `<Space>gb` | Blame line |
| `<Space>gd` | Diff this file |

### Code — `<Space>c`

| Key | Mode | Action |
|-----|------|--------|
| `<Space>cf` | n | Format buffer |
| `gcc` | n | Toggle comment (line) — built-in |
| `gc` | v | Toggle comment (selection) — built-in |

### Debug — `<Space>d`

| Key | Mode | Action |
|-----|------|--------|
| `<Space>db` | n | Toggle breakpoint |
| `<Space>dB` | n | Conditional breakpoint |
| `<Space>dc` / `F5` | n | Continue / Start |
| `<Space>di` / `F11` | n | Step into |
| `<Space>do` / `F10` | n | Step over |
| `<Space>dO` / `Shift+F11` | n | Step out |
| `<Space>dr` | n | Toggle REPL |
| `<Space>dl` | n | Run last |
| `<Space>dt` | n | Terminate |
| `<Space>du` | n | Toggle DAP UI |
| `<Space>de` | n, v | Eval expression |
| `F9` | n | Toggle breakpoint |

### Unreal Engine — `<Space>U`

> These keymaps only exist when Neovim is opened inside a directory containing a `.uproject` file.

| Key | Action |
|-----|--------|
| `<Space>Uf` | Find project files |
| `<Space>Ug` | Grep project |
| `<Space>Uc` | Browse classes |
| `<Space>Us` | Browse structs |
| `<Space>Ue` | Browse enums |
| `<Space>Ui` | Add #include |
| `<Space>UG` | Go to definition (UE) |
| `<Space>UI` | Go to implementation (UE) |
| `<Space>Ur` | Refresh project cache |
| `<Space>UR` | Server status |
| `<Space>Ub` | Build |
| `<Space>UB` | Build (pick target) |
| `<Space>Uj` | Generate compile_commands.json |
| `<Space>UJ` | Generate .sln |
| `<Space>Uh` | Generate headers (UHT) |
| `<Space>UE` | Build diagnostics |
| `<Space>UX` | Run (pick target) |
| `<Space>Un` | New UE class |
| `<Space>Uo` | Switch header/source (UE) |
| `<Space>UO` | Generate .cpp from .h |
| `<Space>Uk` | Insert UE specifiers |
| `<Space>Ua` | Blueprint usages |
| `<Space>UA` | Asset references |
| `<Space>UD` | Debug (default target) |
| `<Space>US` | Debug (select target) |

### Completion (blink.cmp)

| Key | Mode | Action |
|-----|------|--------|
| `Ctrl+Space` | i | Toggle completion menu |
| `Ctrl+Y` | i | Accept selection |
| `Ctrl+E` | i | Dismiss menu |
| `Ctrl+N` / `Ctrl+P` | i | Next / previous item |
| `Ctrl+B` / `Ctrl+F` | i | Scroll docs up / down |
| `Tab` / `Shift+Tab` | i, s | Jump snippet placeholders |
| `Ctrl+K` | i | Toggle signature help |

## How to Extend

### Adding a new plugin

Create a new file in `lua/plugins/`, e.g. `lua/plugins/my-plugin.lua`:

```lua
return {
  'author/plugin-name',
  event = 'VeryLazy',  -- or other lazy-loading trigger
  opts = {
    -- plugin options
  },
}
```

Restart Neovim — lazy.nvim auto-discovers new files.

### Adding a new LSP server

1. Add the server name to `ensure_installed` in `lua/plugins/lsp.lua`
2. Optionally configure it with `vim.lsp.config('server_name', { ... })`
3. mason-lspconfig auto-enables installed servers

### Adding language-specific features

Create a file like `lua/plugins/lang-python.lua` that bundles:
- Treesitter parsers
- LSP server config
- Formatter config
- DAP config (when ready)

This keeps language support modular and removable.

## Unreal Engine 5 Setup

The UE5 suite loads automatically when Neovim is opened inside a project containing a `.uproject` file. Outside UE projects, these plugins have **zero overhead** — they are completely excluded from loading.

### First-time setup

1. Install prerequisites: `scoop install fd rustup` then `rustup default stable`
2. Open Neovim — lazy.nvim will install UE plugins and build the UNL.nvim Rust scanner
3. Open Neovim in your UE project root — `.clangd` is auto-created with UE-appropriate settings
4. Run `:UBT gen_compile_db` to generate `compile_commands.json` for clangd
5. Run `:UNL refresh` to scan the project structure
6. clangd will begin background indexing (first run takes hours; subsequent runs are fast)
