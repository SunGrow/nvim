local cmp = require('cmp')
local luasnip = require('luasnip')

cmp.setup({
  snippet = {
    expand = function(args)
      luasnip.lsp_expand(args.body)  -- Properly expand snippets using LuaSnip
    end,
  },
  mapping = cmp.mapping.preset.insert({
    ['<C-p>'] = cmp.mapping.select_prev_item(),        -- Select previous completion item
    ['<C-n>'] = cmp.mapping.select_next_item(),        -- Select next completion item
    ['<C-d>'] = cmp.mapping.scroll_docs(-4),           -- Scroll documentation up
    ['<C-f>'] = cmp.mapping.scroll_docs(4),            -- Scroll documentation down
    ['<C-Space>'] = cmp.mapping.complete(),            -- Trigger completion menu
    ['<C-e>'] = cmp.mapping.abort(),                   -- Abort the completion menu
    ['<CR>'] = cmp.mapping.confirm({ select = true }), -- Confirm selection

    -- Tab completion and snippet navigation
    ['<Tab>'] = cmp.mapping(function(fallback)
      if cmp.visible() then
        cmp.select_next_item()                         -- Select the next completion item
      elseif luasnip.expand_or_jumpable() then
        luasnip.expand_or_jump()                       -- Expand or jump to the next snippet position
      else
        fallback()                                     -- Use default <Tab> behavior
      end
    end, { 'i', 's' }),

    ['<S-Tab>'] = cmp.mapping(function(fallback)
      if cmp.visible() then
        cmp.select_prev_item()                         -- Select the previous completion item
      elseif luasnip.jumpable(-1) then
        luasnip.jump(-1)                               -- Jump to the previous snippet position
      else
        fallback()                                     -- Use default <S-Tab> behavior
      end
    end, { 'i', 's' }),
  }),
  sources = cmp.config.sources({
    { name = 'nvim_lsp' },                             -- LSP source for language server completion
    { name = 'luasnip' },                              -- Snippet source
    -- { name = 'codecompanion' },                        -- Integrate codecompanion source for AI-powered suggestions
  }, {
    { name = 'buffer' },                               -- Buffer source for text in the current buffer
    { name = 'path' },                                 -- Path source for file paths
  })
})
