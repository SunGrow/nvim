-- From a line to the commit that last changed it, shown in diffview (Rider's "Annotate with Git Blame",
-- then a click on a line's commit). `<leader>go` asks git blame for the cursor line; in gitsigns' blame
-- panel (`<leader>ga`), Enter or a double-click opens that line's commit. The commit opens on the file
-- it was blamed in. From WSL, `git` is bin/wsl/git (git.exe for Windows drives).
local M = {}

local function notify(msg, level) vim.notify(msg, level or vim.log.levels.INFO, { title = 'Git' }) end

--- Opens `sha`'s changes in diffview, on `path` (relative to the repository root) when given.
function M.open_commit(sha, path)
  if not sha or sha:match('^0+$') then return notify('Not committed yet') end
  local cmd = 'DiffviewOpen ' .. sha .. '^!'
  if path then cmd = cmd .. ' --selected-file=' .. vim.fn.fnameescape(path) end
  vim.cmd(cmd)
end

--- The commit that last changed the cursor line of the current file.
function M.line_commit()
  local file = vim.api.nvim_buf_get_name(0)
  if file == '' or vim.bo.buftype ~= '' then return notify('Not a file', vim.log.levels.WARN) end
  local dir, name = vim.fs.dirname(file), vim.fs.basename(file)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  -- a modified buffer: blame the saved file at the same line (the line may have moved)
  vim.system({ 'git', 'blame', '--porcelain', '-L', lnum .. ',' .. lnum, '--', name }, { cwd = dir, text = true },
    vim.schedule_wrap(function(res)
      local sha = res.code == 0 and (res.stdout or ''):match('^(%x+)') or nil
      if not sha then return notify('git blame: ' .. vim.trim(res.stderr or ''), vim.log.levels.WARN) end
      local path = (res.stdout or ''):match('\nfilename ([^\n]+)')
      -- --selected-file is relative to the repository root; blame's filename is relative to it too
      M.open_commit(sha, path)
    end))
end

-- The blame panel's title shows its keys, most needed first, as many as its width holds; `?` lists
-- all of them (r, R, d, s, S are gitsigns' own).
local PANEL_HINTS = { '⏎ commit', 'm menu', '? keys', 'q close', 'r reblame' }
local PANEL_HELP = {
  '  ⏎ / double-click   open the commit of this line (diffview)',
  '  m                  menu: reblame, diff, show commit',
  '  r / R              reblame at this commit / at its parent',
  '  d                  diff of this commit (tab)',
  '  s / S              show the commit (split / tab)',
  '  q                  close the panel',
}

--- Winbar text for the blame panel (evaluated on every redraw).
function M.blame_winbar()
  local win = vim.g.statusline_winid or 0
  local room = (vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win) or 40) - #'Blame' - 3
  local kept = {}
  for _, h in ipairs(PANEL_HINTS) do
    if vim.fn.strdisplaywidth(table.concat(vim.list_extend(vim.list_slice(kept), { h }), ' · ')) > room then break end
    kept[#kept + 1] = h
  end
  return '%#Title#Blame%*' .. (#kept > 0 and '   ' .. table.concat(kept, ' · ') or '')
end

-- gitsigns' blame panel shows a hash only on the first line of each block, so the commit comes from
-- gitsigns' blame of the file (its cache entry: commit and the file's name in that commit, renames
-- included). Its own <CR> (a menu) is set after the FileType event, so the panel's keys are set on the
-- next loop iteration.
vim.api.nvim_create_autocmd('FileType', {
  group = vim.api.nvim_create_augroup('git-history-blame', { clear = true }),
  pattern = 'gitsigns-blame',
  callback = function(ev)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(ev.buf) then return end
      -- the panel sits next to the blamed file's window (scrollbound to it)
      local function blamed()
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          local b = vim.api.nvim_win_get_buf(w)
          local entry = b ~= ev.buf and vim.wo[w].scrollbind and require('gitsigns.cache').cache[b]
          if entry and entry.blame then return w, entry.blame end
        end
      end
      local function open()
        local _, blame = blamed()
        local info = blame and blame.entries[vim.api.nvim_win_get_cursor(0)[1]]
        if info then return M.open_commit(info.commit.sha, info.filename) end
        notify('No blame for this line', vim.log.levels.WARN)
      end
      local function map(lhs, rhs, desc) vim.keymap.set('n', lhs, rhs, { buffer = ev.buf, desc = desc }) end
      map('<CR>', open, 'Open this commit (diffview)')
      map('<2-LeftMouse>', open, 'Open this commit (diffview)')
      map('m', function() vim.cmd.popup(']GitsignsBlame') end, 'Blame menu (reblame, show commit)')
      map('q', '<cmd>close<CR>', 'Close the blame panel')
      map('?', function() require('core.keyhelp').float('Blame panel keys', PANEL_HELP) end, 'Blame panel keys')

      -- the title with the keys; the file's window gets one too (its name), or the scrollbound lines
      -- would be one row apart. Its own winbar comes back when the panel closes.
      local panel = vim.fn.win_findbuf(ev.buf)[1]
      local file_win = blamed()
      if not panel then return end
      vim.wo[panel][0].winbar = "%{%v:lua.require'core.git_history'.blame_winbar()%}"
      if file_win and vim.wo[file_win].winbar == '' then
        vim.wo[file_win].winbar = '%#Title#%{fnamemodify(bufname(),":~:.")}%*'
        vim.api.nvim_create_autocmd('WinClosed', {
          pattern = tostring(panel),
          once = true,
          callback = function()
            if vim.api.nvim_win_is_valid(file_win) then vim.wo[file_win].winbar = '' end
          end,
        })
      end
    end)
  end,
})

return M
