return {
  'saghen/blink.cmp',
  event = 'VimEnter',
  version = '1.*',
  opts = {
    keymap = { preset = 'default' },
    appearance = {
      nerd_font_variant = 'mono',
    },
    completion = {
      documentation = { auto_show = true, auto_show_delay_ms = 200 },
    },
    sources = {
      default = { 'lsp', 'path', 'snippets', 'buffer' },
    },
    signature = { enabled = true },
    fuzzy = { implementation = 'lua' },
  },
  opts_extend = { 'sources.default' },
}
