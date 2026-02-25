# Neovim Configuration

A performance-first, extensible Neovim configuration built on Neovim 0.11+ with lazy.nvim.

## Philosophy

1. **Built-in first** — leverages Neovim 0.11 native LSP keymaps, commenting, snippets, and diagnostics before reaching for plugins
2. **Lazy everything** — all plugins lazy-loaded; startup target < 50ms
3. **Modular** — one file per concern in `lua/plugins/`; add/remove features by adding/removing files
4. **Discoverable** — which-key.nvim popup shows available keybindings as you type
5. **Minimal dependencies** — ~14 plugins total (down from 31)

## Prerequisites

| Dependency | Required | Purpose |
|------------|----------|---------|
| [Neovim](https://neovim.io/) 0.11+ | yes | Editor |
| [Git](https://git-scm.com/) | yes | Plugin installation |
| [Nerd Font](https://www.nerdfonts.com/) | yes | Icons (devicons, lualine, which-key) |
| [ripgrep](https://github.com/BurntSushi/ripgrep) | yes | Telescope live grep |
| [make](https://www.gnu.org/software/make/) | optional | Builds telescope-fzf-native for faster sorting |
| C compiler (gcc/clang) | optional | Treesitter parser compilation |

### Windows (scoop)

```powershell
scoop install neovim git ripgrep make
scoop bucket add nerd-fonts
scoop install JetBrainsMono-NF
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
│       ├── ui.lua            lualine + which-key
│       ├── editor.lua        hardtime (habit training)
│       ├── telescope.lua     Fuzzy finder
│       ├── lsp.lua           LSP + mason + lazydev
│       ├── completion.lua    blink.cmp
│       ├── formatting.lua    conform.nvim
│       └── git.lua           gitsigns
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

## Keybindings

Leader key: `Space`

### General

| Key | Mode | Action |
|-----|------|--------|
| `<Esc>` | n | Clear search highlight |
| `<Space>w` | n | Window mode (followed by split commands) |
| `<Space>e` | n | File explorer (netrw) |
| `<Space>s` | n | Save file |
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
