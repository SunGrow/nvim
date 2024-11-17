require("lazy").setup({
  "folke/lazy.nvim",

  -- Visual Themes
  { "catppuccin/nvim", name = "catppuccin" },
  { "NLKNguyen/papercolor-theme", name = "papercolor" },
  { "folke/tokyonight.nvim", name = "tokyonight" },
  { "ayu-theme/ayu-vim", name = "ayu" },
  { "morhetz/gruvbox", name = "gruvbox" },

  -- UI Enhancements
  "ap/vim-css-color",
  "ryanoasis/vim-devicons",
  {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
  },
  "stevearc/dressing.nvim",
  "rcarriga/nvim-notify",

  -- Telescope
  {
    "nvim-telescope/telescope.nvim",
    branch = "0.1.x",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-treesitter/nvim-treesitter",
      { "nvim-telescope/telescope-fzf-native.nvim", build = "make" },
    },
  },

  -- Overseer (Task Manager)
  {
    "stevearc/overseer.nvim",
    config = function()
      require("overseer").setup()
    end,
  },

  -- Hardtime (Keybinding Restrictions)
  {
    "m4xshen/hardtime.nvim",
    dependencies = { "MunifTanjim/nui.nvim", "nvim-lua/plenary.nvim" },
    opts = {},
  },

  -- LSP and Related Plugins
  {
    "neovim/nvim-lspconfig",
    dependencies = {
      "ray-x/guihua.lua",
      "Civitasv/cmake-tools.nvim",
      {
        "pmizio/typescript-tools.nvim",
        dependencies = { "nvim-lua/plenary.nvim", "neovim/nvim-lspconfig" },
      },
      {
        "stevearc/conform.nvim",
        config = function()
          require("conform").setup()
        end,
      },
      "mfussenegger/nvim-dap",
      { "folke/neodev.nvim", opts = {}, dependencies = { "nvim-neotest/nvim-nio" } },
      { "rcarriga/nvim-dap-ui", dependencies = { "mfussenegger/nvim-dap", "nvim-neotest/nvim-nio" } },
    },
  },

  -- Completion
  "hrsh7th/nvim-cmp",
  "hrsh7th/cmp-nvim-lsp",
  "hrsh7th/cmp-buffer",
  "hrsh7th/cmp-path",
  "hrsh7th/cmp-cmdline",
  "ray-x/lsp_signature.nvim",

  -- Snippets
  "saadparwaiz1/cmp_luasnip",
  "L3MON4D3/LuaSnip",

  -- LSP Installer and Trouble
  "williamboman/nvim-lsp-installer",
  "folke/lsp-trouble.nvim",
  "lervag/vimtex",
  
  -- fzf with corrected build function
  {
    "junegunn/fzf.vim",
    lazy = true,
    cmd = { "Files", "Buffers", "Rg", "GFiles", "History" },
    dependencies = {
      "junegunn/fzf",
      build = "./install --bin",
    },
    config = function()
      vim.g.fzf_vim = {
        command_prefix = "Fzf",
        preview_window = { 'right,50%', 'ctrl-/' },
        history_dir = '~/.config/local/share/fzf-vim-history',
      }
      vim.g.fzf_action = {
        ["ctrl-t"] = "tabedit",
        ["ctrl-v"] = "vsplit",
        ["ctrl-s"] = "split",
      }
    end,
  },

  "ojroques/nvim-lspfuzzy",
  "habamax/vim-godot",

  -- Game and Tools
  "ThePrimeagen/vim-be-good",

  -- TypeScript DAP
  {
    "mxsdev/nvim-dap-vscode-js",
    dependencies = { "mfussenegger/nvim-dap" },
  },

  -- Git Integration
  {
    "NeogitOrg/neogit",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "sindrets/diffview.nvim",
      "nvim-telescope/telescope.nvim",
      "ibhagwan/fzf-lua",
    },
    config = true,
  },

  "ray-x/go.nvim",

  -- -- CodeCompanion
  -- {
  --   "olimorris/codecompanion.nvim",
  --   config = function()
  --     require("codecompanion").setup({
  --       provider = "ollama",
  --       server = "http://localhost:11434",
  --       ollama_url = "http://localhost:11434",
  --       model = "codellama",
  --     })
  --   end,
  -- },
}, {
  -- Optional: Lazy.nvim options
})

-- Automatically synchronize plugins on first install
if LazyBootstrap then
  require("lazy").sync()
end
