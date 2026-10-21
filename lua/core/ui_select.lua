-- vim.ui.select as a small Telescope list (type to filter, arrows/Ctrl-n/p, Enter, Esc cancels).
--
-- Neovim's default is inputlist(): a numbered list on the command line with "Type number and
-- <Enter>". Everything that offers choices goes through vim.ui.select: code actions (Alt+Enter, shown
-- at the cursor like Rider's), run configurations, exception filters, Blueprint values, new class.
local M = {}
-- Neovim's own select (kept across hot reloads, when vim.ui.select is already this module's)
M.state = { native = vim.ui.select }

function M.select(items, opts, on_choice)
  opts = opts or {}
  local ok = pcall(require, 'telescope')
  if not ok or #items == 0 then return M.state.native(items, opts, on_choice) end
  local actions = require('telescope.actions')
  local state = require('telescope.actions.state')
  local themes = require('telescope.themes')
  local conf = require('telescope.config').values

  local fmt = opts.format_item or tostring
  local entries, width = {}, 30
  for i, item in ipairs(items) do
    local text = fmt(item):gsub('\n', ' ')
    entries[i] = { idx = i, item = item, text = text }
    width = math.max(width, vim.fn.strdisplaywidth(text) + 8)
  end
  local title = (opts.prompt or 'Select'):gsub('[:%s]+$', '')
  local layout = {
    width = math.min(width, math.floor(vim.o.columns * 0.8)),
    height = math.min(#items + 4, math.floor(vim.o.lines * 0.6)),
  }
  local theme = opts.kind == 'codeaction' and themes.get_cursor({ layout_config = layout })
    or themes.get_dropdown({ layout_config = layout })

  local done = false
  local function finish(e)
    if done then return end
    done = true
    if e then on_choice(e.item, e.idx) else on_choice(nil, nil) end
  end
  require('telescope.pickers').new(theme, {
    prompt_title = title,
    finder = require('telescope.finders').new_table({
      results = entries,
      entry_maker = function(e) return { value = e, display = e.text, ordinal = e.text } end,
    }),
    sorter = conf.generic_sorter(theme),
    previewer = false,
    attach_mappings = function(bufnr)
      actions.select_default:replace(function()
        local e = state.get_selected_entry()
        actions.close(bufnr)
        finish(e and e.value)
      end)
      -- Esc / closing without a choice still answers the caller (with nil)
      actions.close:enhance({ post = function() vim.schedule(function() finish(nil) end) end })
      return true
    end,
  }):find()
end

function M.setup()
  vim.ui.select = M.select
end

M.on_reload = M.setup

return M
