-- Unreal RPC / BlueprintNativeEvent helpers (Rider for Unreal's "go to related" and "generate missing
-- definitions" for Foo / Foo_Implementation / Foo_Validate).
--
-- Lookups ask clangd only (workspace/symbol with the exact names, switchSourceHeader), so they work in
-- Windows Neovim and in WSL Neovim (Windows clangd.exe with path mappings answers in the caller's
-- spelling) and need none of the UNL / UEP / UCM plugins. The UFUNCTION(...) specifiers and the
-- declaration are read from buffer text: UHT's macros are not code clangd could report them from.
local M = {}

local FUNCTIONS = { [6] = true, [9] = true, [12] = true } -- LSP SymbolKind Method, Constructor, Function

local function warn(msg, title) vim.notify(msg, vim.log.levels.WARN, { title = title }) end

local function client_for(buf)
  local c = vim.lsp.get_clients({ bufnr = buf, name = 'clangd' })[1]
  if c then return c end
  for _, other in ipairs(vim.lsp.get_clients({ name = 'clangd' })) do
    if not other:is_stopped() then return other end
  end
end

-- Text parsing ----------------------------------------------------------------------------------------

--- Text without comments; strings are kept and every newline stays, so line numbers still match.
local function strip_comments(text)
  local out, i, n = {}, 1, #text
  while i <= n do
    local c, two = text:sub(i, i), text:sub(i, i + 1)
    if two == '//' then
      i = text:find('\n', i, true) or n + 1
    elseif two == '/*' then
      local _, e = text:find('*/', i + 2, true)
      e = e or n
      out[#out + 1] = ' ' .. text:sub(i, e):gsub('[^\n]', '')
      i = e + 1
    elseif c == '"' then
      local j = i + 1
      while j <= n and text:sub(j, j) ~= '"' do j = j + (text:sub(j, j) == '\\' and 2 or 1) end
      out[#out + 1] = text:sub(i, j)
      i = j + 1
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

local OPEN, CLOSE = { ['('] = true, ['['] = true, ['{'] = true, ['<'] = true }, { [')'] = true, [']'] = true, ['}'] = true, ['>'] = true }

--- Splits at the commas outside brackets (`TMap<FName, int32>` and `meta=(A, B)` stay whole).
local function split_top(s)
  local parts, depth, from = {}, 0, 1
  for i = 1, #s do
    local c = s:sub(i, i)
    if OPEN[c] then depth = depth + 1
    elseif CLOSE[c] and not (c == '>' and s:sub(i - 1, i - 1) == '-') then depth = depth - 1
    elseif c == ',' and depth == 0 then
      parts[#parts + 1] = vim.trim(s:sub(from, i - 1))
      from = i + 1
    end
  end
  local last = vim.trim(s:sub(from))
  if last ~= '' then parts[#parts + 1] = last end
  return parts
end

--- Index of the parenthesis closing the one at `open`.
local function match_paren(s, open)
  local depth, i, n = 0, open, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == '"' then
      i = i + 1
      while i <= n and s:sub(i, i) ~= '"' do i = i + (s:sub(i, i) == '\\' and 2 or 1) end
    elseif c == '(' then depth = depth + 1
    elseif c == ')' then
      depth = depth - 1
      if depth == 0 then return i end
    end
    i = i + 1
  end
end

local LEADING = { virtual = true, static = true, inline = true, friend = true, constexpr = true, FORCEINLINE = true,
  FORCENOINLINE = true, FORCEINLINE_DEBUGGABLE = true, UE_NODISCARD = true, ['[[nodiscard]]'] = true }

--- Return type as written in the definition: without virtual / static / FORCEINLINE / MODULE_API.
local function clean_return(ret)
  local changed = true
  while changed do
    changed = false
    ret = vim.trim(ret)
    local word = ret:match('^(%S+)')
    if word and (LEADING[word] or word:match('^[%u%d_]+_API$')) then
      ret = ret:sub(#word + 1)
      changed = true
    end
  end
  return ret
end

--- Name of the class whose body holds line `lnum` (nearest class / struct line above it).
local function enclosing_class(buf, lnum)
  for l = lnum, 1, -1 do
    local line = vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1] or ''
    if line:match('^%s*class%s') or line:match('^%s*struct%s') then
      if not (line:find(';', 1, true) and not line:find('{', 1, true)) then -- not a forward declaration
        line = line:gsub('%b()', '')
        line = line:gsub('{.*', '')
        local colon = line:find('[^:]:[^:]')
        if colon then line = line:sub(1, colon) end
        local name
        for word in line:gmatch('[%a_][%w_]*') do
          if word ~= 'final' and word ~= 'class' and word ~= 'struct' and not word:match('_API$') then name = word end
        end
        if name then return name end
      end
    end
  end
end

--- The UFUNCTION declaration holding line `lnum` of a header buffer: specifiers (lower case set), name,
--- return type, parameters without default arguments, const, enclosing class. Multi-line is fine.
--- Returns nil and a message when the line is not in one.
local function parse_ufunction(buf, lnum)
  local first
  for l = lnum, math.max(1, lnum - 60), -1 do
    local line = vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1] or ''
    if line:find('UFUNCTION%s*%(') and not line:match('^%s*//') then first = l; break end
  end
  if not first then return nil, 'The cursor is not on a UFUNCTION declaration' end
  local text = strip_comments(table.concat(vim.api.nvim_buf_get_lines(buf, first - 1, first + 60, false), '\n'))
  local _, e = text:find('UFUNCTION%s*%(')
  local close = match_paren(text, e)
  if not close then return nil, 'UFUNCTION(...) is not closed' end
  local specs = {}
  for _, item in ipairs(split_top(text:sub(e + 1, close - 1))) do
    local key = item:match('^([%w_]+)')
    if key then specs[key:lower()] = true end
  end
  -- the declaration ends at the first ';' or '{' outside parentheses
  local depth, stop = 0, nil
  for i = close + 1, #text do
    local c = text:sub(i, i)
    if c == '(' then depth = depth + 1
    elseif c == ')' then depth = depth - 1
    elseif depth == 0 and (c == ';' or c == '{') then stop = i; break end
  end
  if not stop then return nil, 'No declaration after UFUNCTION(...)' end
  local _, newlines = text:sub(1, stop):gsub('\n', '')
  if first + newlines < lnum then return nil, 'The cursor is not on a UFUNCTION declaration' end
  local decl = text:sub(close + 1, stop - 1)
  local open = decl:find('(', 1, true)
  if not open then return nil, 'No function declaration after UFUNCTION(...)' end
  local head = decl:sub(1, open - 1)
  local name = head:match('([%a_][%w_]*)%s*$')
  local rparen = match_paren(decl, open)
  if not name or not rparen then return nil, 'Could not read the function declaration' end
  local params = {}
  for _, p in ipairs(split_top(decl:sub(open + 1, rparen - 1))) do
    local depth2 = 0
    for i = 1, #p do -- cut the default argument at the first '=' outside brackets
      local c = p:sub(i, i)
      if OPEN[c] then depth2 = depth2 + 1 elseif CLOSE[c] then depth2 = depth2 - 1
      elseif c == '=' and depth2 == 0 then p = vim.trim(p:sub(1, i - 1)); break end
    end
    p = p:gsub('UPARAM%b()%s*', '')
    if p ~= '' and p ~= 'void' then params[#params + 1] = p end
  end
  local _, before = text:sub(1, close + #head):gsub('\n', '')
  return {
    specs = specs,
    name = name,
    name_lnum = first + before, -- line of the name
    ret = clean_return(head:sub(1, #head - #name)),
    params = params,
    const = decl:sub(rparen + 1):find('%f[%w_]const%f[^%w_]') ~= nil,
    class = enclosing_class(buf, first),
  }
end

-- Go to related ---------------------------------------------------------------------------------------

local SUFFIXES = { '_Implementation', '_Validate' }

--- `Foo` for Foo, Foo_Implementation and Foo_Validate.
local function base_name(word)
  for _, suffix in ipairs(SUFFIXES) do
    if #word > #suffix and word:sub(-#suffix) == suffix then return word:sub(1, -#suffix - 1) end
  end
  return word
end

local function generated(uri) return uri:find('/Intermediate/', 1, true) ~= nil end

--- Function symbols of exactly these names (one workspace/symbol request each, in parallel), without the
--- UHT-generated files: `cb({name = {symbol, ...}})`.
local function lookup(client, names, cb)
  local found, pending = {}, #names
  for _, name in ipairs(names) do
    found[name] = {}
    client:request('workspace/symbol', { query = name }, function(_, res)
      for _, s in ipairs(res or {}) do
        if s.name == name and FUNCTIONS[s.kind] and s.location and not generated(s.location.uri) then
          table.insert(found[name], s)
        end
      end
      pending = pending - 1
      if pending == 0 then cb(found) end
    end)
  end
end

--- Class of the function at the cursor, from the text (`Class::Foo`, or the enclosing class in a header);
--- `cb(class)` with nil when the text does not say (a call `Obj->Foo()`).
local function class_hint(buf, client, word, cb)
  local line = vim.api.nvim_get_current_line()
  local qualified = line:match('([%a_][%w_]*)::' .. word .. '%f[^%w_]')
  if qualified then return cb(qualified) end
  if vim.api.nvim_buf_get_name(buf):match('%.h[%w]*$') and line:find('UFUNCTION', 1, true) == nil then
    -- a declaration line: the enclosing class, unless the word is a call inside an inline body
    local cls = enclosing_class(buf, vim.api.nvim_win_get_cursor(0)[1])
    if cls then return cb(cls) end
  end
  cb(nil)
end

local function same_class(container, class)
  return container == class or container:sub(-#class - 2) == '::' .. class
end

--- Jump to Foo_Implementation, Foo_Validate and the Foo declaration related to the function at the
--- cursor (a UFUNCTION declaration, a call, or one of those definitions); a list when there are several.
function M.goto_related()
  local title = 'Related functions'
  local buf = vim.api.nvim_get_current_buf()
  local client = client_for(buf)
  if not client then return warn('No clangd for this file', title) end
  local word = vim.fn.expand('<cword>')
  local line = vim.api.nvim_get_current_line()
  local name_lnum = vim.api.nvim_win_get_cursor(0)[1]
  if line:find('UFUNCTION%s*%(') then -- on the macro: the function it declares
    local fn = parse_ufunction(buf, vim.api.nvim_win_get_cursor(0)[1])
    if fn then word, name_lnum = fn.name, fn.name_lnum end
  end
  if word == '' then return warn('No function name at the cursor', title) end
  local base = base_name(word)
  local here = { uri = vim.uri_from_bufnr(buf), line = name_lnum - 1 } -- not offered as a target

  class_hint(buf, client, word, function(hint)
    lookup(client, { base, base .. SUFFIXES[1], base .. SUFFIXES[2] }, function(found)
      local targets, seen = {}, {}
      for _, name in ipairs({ base, base .. SUFFIXES[1], base .. SUFFIXES[2] }) do
        for _, s in ipairs(found[name]) do
          local start = s.location.range.start
          local key = s.location.uri .. ':' .. start.line
          local mine = s.location.uri == here.uri and start.line == here.line
          if not seen[key] and not mine and (not hint or same_class(s.containerName or '', hint)) then
            seen[key] = true
            local kind = name == base and ' (declaration)' or ''
            local file = vim.fn.fnamemodify(vim.uri_to_fname(s.location.uri), ':t')
            targets[#targets + 1] = {
              location = s.location,
              label = ((s.containerName or '') ~= '' and (s.containerName .. '::') or '') .. name .. kind
                .. '  ' .. file .. ':' .. (start.line + 1),
            }
          end
        end
      end
      if #targets == 0 then
        return vim.notify('No related functions for ' .. base .. ' (clangd may still be indexing)',
          vim.log.levels.INFO, { title = title })
      end
      local function go(target)
        if not target then return end
        vim.cmd("normal! m'") -- so <C-o> comes back here
        vim.lsp.util.show_document(target.location, client.offset_encoding, { focus = true })
      end
      if #targets == 1 then return go(targets[1]) end
      vim.ui.select(targets, { prompt = title, format_item = function(t) return t.label end }, go)
    end)
  end)
end

-- Generate missing definitions ------------------------------------------------------------------------

--- Definitions the declaration needs: RPCs and BlueprintNativeEvent get `_Implementation`, and
--- `_Validate` when WithValidation is given (UE5 Server RPCs need none otherwise).
local function needed(fn)
  local s = fn.specs
  local rpc = s.server or s.client or s.netmulticast
  local out = {}
  if rpc or s.blueprintnativeevent then out[#out + 1] = SUFFIXES[1] end
  if rpc and s.withvalidation then out[#out + 1] = SUFFIXES[2] end
  return out
end

--- Lines of one definition: `Ret Class::Foo_Implementation(Params) const` with an empty body.
local function definition(fn, suffix)
  local ret = suffix == '_Validate' and 'bool' or fn.ret
  local sig = ret .. ' ' .. fn.class .. '::' .. fn.name .. suffix .. '(' .. table.concat(fn.params, ', ') .. ')'
    .. (fn.const and ' const' or '')
  local body
  if suffix == '_Validate' then body = '\treturn true;'
  elseif ret == 'void' or ret:find('&', 1, true) then body = nil -- no value to return (a reference has none)
  elseif ret:find('*', 1, true) then body = '\treturn nullptr;'
  else body = '\treturn {};' end
  return body and { sig, '{', body, '}' } or { sig, '{', '}' }
end

--- Line after which new definitions go: the end of the class's last member function defined at the top
--- level of the .cpp (outside #if blocks such as WITH_EDITOR, where they would compile only there), else
--- the end of the file. Braces are counted with strings, character literals and comments removed.
local function insert_after(lines, class)
  local head = '^[%w_].-' .. class .. '%s*::%s*~?[%w_]+%s*%('
  local pp, depth, last, open = 0, 0, nil, nil
  local in_block = false
  for i, raw in ipairs(lines) do
    local l = raw
    if in_block then
      local e = l:find('*/', 1, true)
      if not e then goto continue end
      l, in_block = l:sub(e + 2), false
    end
    l = l:gsub('\\.', ''):gsub('"[^"]*"', '""'):gsub("'[^']*'", "''"):gsub('/%*.-%*/', '')
    do
      local c = l:find('/*', 1, true)
      if c then l, in_block = l:sub(1, c - 1), true end
    end
    l = l:gsub('//.*$', '')
    if l:match('^%s*#%s*if') then pp = pp + 1
    elseif l:match('^%s*#%s*endif') then pp = math.max(0, pp - 1)
    elseif pp == 0 and depth == 0 and l:match(head) then open = i end
    for ch in l:gmatch('[{}]') do
      depth = depth + (ch == '{' and 1 or -1)
      if depth == 0 and open and ch == '}' then last, open = i, nil end
    end
    if depth < 0 then depth = 0 end
    ::continue::
  end
  return last or #lines
end

--- The .cpp of a header: clangd's switchSourceHeader, else the same name next to it; `cb(path)`.
local function source_of(buf, client, cb)
  local function fallback()
    local guess = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':r') .. '.cpp'
    cb(vim.uv.fs_stat(guess) and guess or nil)
  end
  client:request('textDocument/switchSourceHeader', { uri = vim.uri_from_bufnr(buf) }, function(err, uri)
    if err or type(uri) ~= 'string' or uri == '' then return fallback() end
    cb(vim.uri_to_fname(uri))
  end, buf)
end

--- On a UFUNCTION declaration (Server / Client / NetMulticast RPC, BlueprintNativeEvent): adds the
--- `_Implementation` (and `_Validate`) definitions missing from the matching .cpp, with the declaration's
--- signature and an empty body, after the class's last definition there, and opens the .cpp at them. UHT
--- declares them in the header; nothing is added there. The .cpp is left modified, not saved.
function M.generate_missing()
  local title = 'Generate RPC definitions'
  local buf = vim.api.nvim_get_current_buf()
  local fn, err = parse_ufunction(buf, vim.api.nvim_win_get_cursor(0)[1])
  if not fn then return warn(err, title) end
  local suffixes = needed(fn)
  if #suffixes == 0 then
    return warn(fn.name .. ' is not a Server / Client / NetMulticast RPC or BlueprintNativeEvent', title)
  end
  if not fn.class then return warn('Could not find the class of ' .. fn.name, title) end
  local client = client_for(buf)
  if not client then return warn('No clangd for this file', title) end

  source_of(buf, client, function(path)
    if not path then return warn('No source file found for this header', title) end
    vim.cmd("normal! m'") -- so <C-o> comes back to the header
    vim.cmd.edit(vim.fn.fnameescape(path))
    local cpp = vim.api.nvim_get_current_buf()
    local kept = {} -- the .cpp without whole-line comments
    for _, l in ipairs(vim.api.nvim_buf_get_lines(cpp, 0, -1, false)) do
      if not l:match('^%s*//') then kept[#kept + 1] = l end
    end
    local text = table.concat(kept, '\n')
    local lines, body_row, existing = {}, nil, {}
    local count = insert_after(vim.api.nvim_buf_get_lines(cpp, 0, -1, false), fn.class)
    for _, suffix in ipairs(suffixes) do
      if text:find(fn.class .. '%s*::%s*' .. fn.name .. suffix .. '%s*%(') then
        existing[#existing + 1] = fn.name .. suffix
      else
        local def = definition(fn, suffix)
        if not body_row then body_row = count + #lines + 4 end -- the line inside the first new body
        table.insert(lines, '')
        vim.list_extend(lines, def)
      end
    end
    if #lines == 0 then
      return vim.notify('Already defined in ' .. vim.fn.fnamemodify(path, ':t') .. ': ' .. table.concat(existing, ', '),
        vim.log.levels.INFO, { title = title })
    end
    vim.api.nvim_buf_set_lines(cpp, count, count, false, lines)
    vim.api.nvim_win_set_cursor(0, { body_row, 0 })
    vim.cmd('normal! zz')
    vim.notify('Added ' .. (#suffixes - #existing) .. ' definition(s) for ' .. fn.class .. '::' .. fn.name
      .. ' (not saved)', vim.log.levels.INFO, { title = title })
  end)
end

return M
