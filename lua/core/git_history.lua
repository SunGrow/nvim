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
      local function open()
        local lnum = vim.api.nvim_win_get_cursor(0)[1]
        -- the panel sits next to the blamed file's window (scrollbound to it)
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          local b = vim.api.nvim_win_get_buf(w)
          local entry = b ~= ev.buf and vim.wo[w].scrollbind and require('gitsigns.cache').cache[b]
          local info = entry and entry.blame and entry.blame.entries[lnum]
          if info then return M.open_commit(info.commit.sha, info.filename) end
        end
        notify('No blame for this line', vim.log.levels.WARN)
      end
      for _, lhs in ipairs({ '<CR>', '<2-LeftMouse>' }) do
        vim.keymap.set('n', lhs, open, { buffer = ev.buf, desc = 'Open this commit (diffview)' })
      end
      vim.keymap.set('n', 'm', function() vim.cmd.popup(']GitsignsBlame') end,
        { buffer = ev.buf, desc = 'Blame menu (reblame, show commit)' })
    end)
  end,
})

return M
