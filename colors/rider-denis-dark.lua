-- Rider's "Denis Dark" editor color scheme (a user copy of Rider Dark, parent Darcula).
-- Colors come from %APPDATA%/JetBrains/Rider2026.2/colors/Denis Dark.icls. Attributes that the
-- scheme does not set come from Rider's bundled RiderDark.xml (rider-theme-pack.jar), via its
-- baseAttributes links. The Rider attribute behind each color is named next to it.
-- clangd semantic tokens carry the C++ distinctions Rider makes (local / global / member, ...).
vim.cmd('highlight clear')
if vim.fn.exists('syntax_on') == 1 then vim.cmd('syntax reset') end
vim.o.background = 'dark'
vim.g.colors_name = 'rider-denis-dark'

local c = {
  bg = '#191a1c',          -- TEXT background
  fg = '#c7bcbc',          -- TEXT foreground
  ident = '#bdbdbd',       -- DEFAULT_IDENTIFIER, operators, braces, punctuation
  bright = '#f0f0f0',      -- DEFAULT_LABEL, DEFAULT_PREDEFINED_SYMBOL, CARET_COLOR
  keyword = '#6c95eb',     -- DEFAULT_KEYWORD, CPP_PREPROCESSOR_MACRO_IDENTIFIER
  string = '#c9a26d',      -- DEFAULT_STRING
  escape = '#d688d4',      -- DEFAULT_VALID_STRING_ESCAPE
  number = '#ed94c0',      -- DEFAULT_NUMBER
  comment = '#3e6e29',     -- DEFAULT_LINE_COMMENT (italic)
  block_comment = '#3f8b27', -- DEFAULT_BLOCK_COMMENT (italic)
  doc_comment = '#7ac25f', -- DEFAULT_DOC_COMMENT (italic)
  doc_tag = '#4c8438',     -- DEFAULT_DOC_COMMENT_TAG
  doxygen = '#a87863',     -- CPP_DOXYGEN_COMMENT (italic)
  func = '#39cc9b',        -- DEFAULT_FUNCTION_DECLARATION / _CALL
  method = '#39cc8f',      -- CPP_MEMBER_FUNCTION_IDENTIFIER
  global = '#c7d720',      -- CPP_GLOBAL_FUNCTION/_VARIABLE, CPP_STATIC_*, CPP_CONSTANT_IDENTIFIER
  operator_fn = '#c7cc39', -- CPP_OVERLOADED_OPERATOR_IDENTIFIER
  class = '#c191ff',       -- DEFAULT_CLASS_NAME, NAMESPACE, TYPE_PARAMETER, UE reflection specifiers
  struct = '#e1bfff',      -- STRUCT/ENUM_IDENTIFIER, CPP_ENUM_ENUMERATOR, CPP_STRUCT_FIELD
  field = '#77ffff',       -- CPP_CLASS_FIELD_IDENTIFIER, DEFAULT_INSTANCE_FIELD
  param = '#66c3cc',       -- CPP_PARAMETER_VARIABLE_IDENTIFIER, DEFAULT_CONSTANT (bold)
  local_var = '#11a5ff',   -- CPP_LOCAL_VARIABLE_IDENTIFIER
  dependent = '#7df0c0',   -- CPP_DEPENDENT_NAME_IDENTIFIER
  attribute = '#85c46c',   -- DEFAULT_ATTRIBUTE, ReSharper.HINT
  entity = '#ffd49e',      -- DEFAULT_ENTITY
  unused = '#787878',      -- NOT_USED_ELEMENT_ATTRIBUTES, INFO_ATTRIBUTES, DEBUGGER_INLINED_VALUES
  error = '#ff5647',       -- ERRORS_ATTRIBUTES
  warning = '#f5d86a',     -- WARNING_ATTRIBUTES
  yellow = '#d9b72b',      -- warning stripe, bookmarks
  link = '#406ac2',        -- HYPERLINK_ATTRIBUTES effect

  caret_row = '#202424',   -- CARET_ROW_COLOR
  gutter = '#282828',      -- GUTTER_BACKGROUND
  line_nr = '#808080',     -- LINE_NUMBERS_COLOR
  popup = '#262626',       -- LOOKUP_COLOR, DOCUMENTATION_COLOR, CONSOLE_BACKGROUND_KEY
  popup_sel = '#303030',   -- INFORMATION_HINT, READONLY_BACKGROUND
  guide = '#404040',       -- INDENT_GUIDE, RIGHT_MARGIN_COLOR, TEARLINE_COLOR
  guide_sel = '#666666',   -- SELECTED_INDENT_GUIDE
  whitespace = '#686868',  -- WHITESPACES
  selection = '#08335e',   -- SELECTION_BACKGROUND
  search = '#484012',      -- TEXT_SEARCH_RESULT_ATTRIBUTES
  search_cur = '#144238',  -- SEARCH_RESULT_ATTRIBUTES
  ref_read = '#232e46',    -- IDENTIFIER_UNDER_CARET_ATTRIBUTES
  ref_write = '#522750',   -- WRITE_SEARCH_RESULT_ATTRIBUTES
  brace = '#422240',       -- MATCHED_BRACE_ATTRIBUTES
  error_bg = '#4a2421',    -- ERROR_HINT, BREAKPOINT_ATTRIBUTES, UNMATCHED_BRACE
  warn_bg = '#3d3020',     -- QUESTION_HINT, NOTIFICATION_BACKGROUND
  exec_bg = '#6b4c1b',     -- EXECUTIONPOINT_ATTRIBUTES
  added = '#2c4722',       -- ADDED_LINES_COLOR
  modified = '#293a5f',    -- MODIFIED_LINES_COLOR
  deleted = '#bf3428',     -- DELETED_LINES_COLOR
  diff_text = '#3d5a80',   -- (no Rider key) changed text inside a modified line
}

local groups = {
  -- Editor
  Normal = { fg = c.fg, bg = c.bg },
  NormalNC = { fg = c.fg, bg = c.bg },
  NormalFloat = { fg = c.fg, bg = c.popup },
  FloatBorder = { fg = c.guide_sel, bg = c.popup },
  FloatTitle = { fg = c.bright, bg = c.popup, bold = true },
  Cursor = { fg = c.bg, bg = c.bright },
  CursorLine = { bg = c.caret_row },
  CursorColumn = { bg = c.caret_row },
  ColorColumn = { bg = c.guide },
  LineNr = { fg = c.line_nr, bg = c.gutter },
  CursorLineNr = { fg = c.line_nr, bg = c.gutter, bold = true },
  SignColumn = { bg = c.gutter },
  FoldColumn = { fg = c.line_nr, bg = c.gutter },
  Folded = { fg = c.unused, bg = c.popup_sel },
  VertSplit = { fg = c.guide },
  WinSeparator = { fg = c.guide },
  StatusLine = { fg = c.ident, bg = c.gutter },
  StatusLineNC = { fg = c.unused, bg = c.popup },
  TabLine = { fg = c.unused, bg = c.popup },
  TabLineFill = { bg = c.popup },
  TabLineSel = { fg = c.bright, bg = c.bg },
  WinBar = { fg = c.ident, bg = c.bg },
  WinBarNC = { fg = c.unused, bg = c.bg },
  Visual = { bg = c.selection },
  VisualNOS = { bg = c.selection },
  Search = { bg = c.search },
  IncSearch = { bg = c.search_cur, bold = true },
  CurSearch = { bg = c.search_cur, bold = true },
  Substitute = { bg = c.ref_write },
  MatchParen = { bg = c.brace, bold = true },
  NonText = { fg = c.guide_sel },
  Whitespace = { fg = c.whitespace },
  SpecialKey = { fg = c.whitespace },
  EndOfBuffer = { fg = c.bg },
  Pmenu = { fg = c.fg, bg = c.popup },
  PmenuSel = { bg = c.selection },
  PmenuSbar = { bg = c.popup_sel },
  PmenuThumb = { bg = c.guide_sel },
  PmenuMatch = { fg = c.keyword, bold = true },
  PmenuMatchSel = { fg = c.keyword, bold = true },
  WildMenu = { bg = c.selection },
  Directory = { fg = c.keyword },
  Title = { fg = c.bright, bold = true },
  Question = { fg = c.attribute },
  MoreMsg = { fg = c.attribute },
  ModeMsg = { fg = c.ident, bold = true },
  ErrorMsg = { fg = c.error },
  WarningMsg = { fg = c.warning },
  QuickFixLine = { bg = c.selection },
  Conceal = { fg = c.unused },
  SpellBad = { sp = c.error, undercurl = true },
  SpellCap = { sp = c.warning, undercurl = true },
  SpellLocal = { sp = c.attribute, undercurl = true },
  SpellRare = { sp = c.class, undercurl = true },

  -- Diff / git (Rider gutter colors)
  DiffAdd = { bg = c.added },
  DiffChange = { bg = c.modified },
  DiffDelete = { fg = c.deleted, bg = c.error_bg },
  DiffText = { bg = c.diff_text },
  Added = { fg = c.attribute },
  Changed = { fg = c.keyword },
  Removed = { fg = c.deleted },
  -- (no Rider key) Rider fills a gutter bar with ADDED/MODIFIED_LINES_COLOR; a sign glyph in
  -- those exact colors is barely visible on the gutter, so these are brighter shades of them.
  GitSignsAdd = { fg = '#3f6e31', bg = c.gutter },
  GitSignsChange = { fg = '#3d5a99', bg = c.gutter },
  GitSignsDelete = { fg = c.deleted, bg = c.gutter },

  -- Legacy syntax groups
  Comment = { fg = c.comment, italic = true },
  Constant = { fg = c.param, bold = true },
  String = { fg = c.string },
  Character = { fg = c.string },
  Number = { fg = c.number },
  Float = { fg = c.number },
  Boolean = { fg = c.keyword },
  Identifier = { fg = c.ident },
  Function = { fg = c.func },
  Statement = { fg = c.keyword },
  Keyword = { fg = c.keyword },
  Conditional = { fg = c.keyword },
  Repeat = { fg = c.keyword },
  Label = { fg = c.bright, bold = true },
  Operator = { fg = c.ident },
  Exception = { fg = c.keyword },
  PreProc = { fg = c.keyword },
  Include = { fg = c.keyword },
  Define = { fg = c.keyword },
  Macro = { fg = c.keyword },
  PreCondit = { fg = c.keyword },
  Type = { fg = c.class },
  StorageClass = { fg = c.keyword },
  Structure = { fg = c.struct },
  Typedef = { fg = c.class },
  Special = { fg = c.escape },
  SpecialChar = { fg = c.escape },
  Tag = { fg = c.class },
  Delimiter = { fg = c.ident },
  SpecialComment = { fg = c.doc_comment, italic = true },
  Debug = { fg = c.warning },
  Underlined = { fg = c.keyword, underline = true, sp = c.link },
  Error = { fg = c.error },
  Todo = { fg = c.fg, bold = true, italic = true }, -- TODO_DEFAULT_ATTRIBUTES (bold italic)

  -- Treesitter
  ['@variable'] = { fg = c.ident },
  ['@variable.builtin'] = { fg = c.keyword },           -- this
  ['@variable.parameter'] = { fg = c.param },
  ['@variable.member'] = { fg = c.field },
  ['@property'] = { fg = c.field },
  ['@constant'] = { fg = c.param, bold = true },
  ['@constant.builtin'] = { fg = c.keyword },           -- nullptr, true
  ['@constant.macro'] = { fg = c.keyword },
  ['@module'] = { fg = c.class },
  ['@label'] = { fg = c.bright, bold = true },
  ['@string'] = { fg = c.string },
  ['@string.escape'] = { fg = c.escape },
  ['@string.special'] = { fg = c.escape },
  ['@string.special.url'] = { fg = c.keyword, underline = true, sp = c.link },
  ['@character'] = { fg = c.string },
  ['@number'] = { fg = c.number },
  ['@boolean'] = { fg = c.keyword },
  ['@type'] = { fg = c.class },
  ['@type.builtin'] = { fg = c.keyword },               -- int, float, void are keywords in Rider
  ['@type.definition'] = { fg = c.class },
  ['@attribute'] = { fg = c.attribute },
  ['@function'] = { fg = c.func },
  ['@function.builtin'] = { fg = c.func },
  ['@function.call'] = { fg = c.func },
  ['@function.method'] = { fg = c.method },
  ['@function.method.call'] = { fg = c.method },
  ['@function.macro'] = { fg = c.keyword },
  ['@constructor'] = { fg = c.class },
  ['@operator'] = { fg = c.ident },
  ['@keyword'] = { fg = c.keyword },
  ['@keyword.directive'] = { fg = c.keyword },
  ['@keyword.import'] = { fg = c.keyword },
  ['@punctuation'] = { fg = c.ident },
  ['@punctuation.special'] = { fg = c.escape },
  ['@comment'] = { fg = c.comment, italic = true },
  ['@comment.documentation'] = { fg = c.doc_comment, italic = true },
  ['@comment.documentation.cpp'] = { fg = c.doxygen, italic = true },
  ['@comment.error'] = { fg = c.error, bold = true },
  ['@comment.warning'] = { fg = c.warning, bold = true },
  ['@comment.todo'] = { fg = c.fg, bold = true, italic = true },
  ['@comment.note'] = { fg = c.attribute, bold = true },
  ['@tag'] = { fg = c.class },
  ['@tag.attribute'] = { fg = c.attribute },
  ['@tag.delimiter'] = { fg = c.ident },
  ['@markup.heading'] = { fg = c.bright, bold = true },
  ['@markup.strong'] = { bold = true },
  ['@markup.italic'] = { italic = true },
  ['@markup.link'] = { fg = c.keyword, underline = true, sp = c.link },
  ['@markup.link.url'] = { fg = c.keyword, underline = true, sp = c.link },
  ['@markup.raw'] = { fg = c.string },
  ['@markup.list'] = { fg = c.keyword },
  ['@diff.plus'] = { fg = c.attribute },
  ['@diff.minus'] = { fg = c.deleted },
  ['@diff.delta'] = { fg = c.keyword },

  -- clangd semantic tokens: the C++ split Rider (ReSharper C++) makes
  ['@lsp.type.class'] = { fg = c.class },                 -- CPP_CLASS_IDENTIFIER -> DEFAULT_CLASS_NAME
  ['@lsp.type.interface'] = { fg = c.class },
  ['@lsp.type.struct'] = { fg = c.struct },
  ['@lsp.type.enum'] = { fg = c.struct },                 -- CPP_ENUM_IDENTIFIER -> ENUM_IDENTIFIER
  ['@lsp.type.enumMember'] = { fg = c.struct },           -- CPP_ENUM_ENUMERATOR_IDENTIFIER
  ['@lsp.type.type'] = { fg = c.class },                  -- CPP_TYPEDEF_IDENTIFIER -> DEFAULT_CLASS_NAME
  ['@lsp.type.typeParameter'] = { fg = c.class },         -- CPP_TEMPLATE_PARAMETER -> TYPE_PARAMETER
  ['@lsp.type.concept'] = { fg = c.class },
  ['@lsp.type.namespace'] = { fg = c.class },             -- NAMESPACE_IDENTIFIER
  ['@lsp.type.macro'] = { fg = c.keyword },               -- CPP_PREPROCESSOR_MACRO_IDENTIFIER
  ['@lsp.type.function'] = { fg = c.global },             -- CPP_GLOBAL_FUNCTION_IDENTIFIER
  ['@lsp.type.method'] = { fg = c.method },               -- CPP_MEMBER_FUNCTION_IDENTIFIER
  ['@lsp.type.property'] = { fg = c.field },              -- CPP_CLASS_FIELD_IDENTIFIER
  ['@lsp.type.parameter'] = { fg = c.param },             -- CPP_PARAMETER_VARIABLE_IDENTIFIER
  ['@lsp.type.variable'] = { fg = c.ident },
  ['@lsp.type.operator'] = { fg = c.ident },
  ['@lsp.type.label'] = { fg = c.bright, bold = true },
  ['@lsp.type.comment'] = { fg = c.unused },              -- clangd: preprocessor-inactive code
  ['@lsp.typemod.variable.functionScope'] = { fg = c.local_var }, -- CPP_LOCAL_VARIABLE_IDENTIFIER
  ['@lsp.typemod.variable.globalScope'] = { fg = c.global },      -- CPP_GLOBAL_VARIABLE_IDENTIFIER
  ['@lsp.typemod.variable.fileScope'] = { fg = c.global },
  ['@lsp.typemod.variable.static'] = { fg = c.global },           -- CPP_STATIC_FIELD_IDENTIFIER
  ['@lsp.typemod.property.static'] = { fg = c.global },
  ['@lsp.typemod.method.static'] = { fg = c.global },             -- CPP_STATIC_MEMBER_FUNCTION_IDENTIFIER
  ['@lsp.typemod.operator.userDefined'] = { fg = c.operator_fn }, -- CPP_OVERLOADED_OPERATOR_IDENTIFIER
  ['@lsp.typemod.type.dependentName'] = { fg = c.dependent },     -- CPP_DEPENDENT_NAME_IDENTIFIER
  ['@lsp.typemod.function.dependentName'] = { fg = c.dependent },
  ['@lsp.typemod.method.dependentName'] = { fg = c.dependent },
  ['@lsp.typemod.unknown.dependentName'] = { fg = c.dependent },
  ['@lsp.mod.deprecated'] = { strikethrough = true, sp = c.warning }, -- DEPRECATED_ATTRIBUTES
  ['@lsp.type.unknown'] = {},
  ['@lsp.type.bracket'] = {},
  ['@lsp.type.modifier'] = {},
  -- Lua LSP: functions are not "global" there
  ['@lsp.type.function.lua'] = { fg = c.func },

  -- Diagnostics (Rider: red/yellow waves, gray "info", green dotted hints)
  DiagnosticError = { fg = c.error },
  DiagnosticWarn = { fg = c.warning },
  DiagnosticInfo = { fg = c.line_nr },
  DiagnosticHint = { fg = c.attribute },
  DiagnosticOk = { fg = c.attribute },
  DiagnosticUnderlineError = { sp = c.error, undercurl = true },
  DiagnosticUnderlineWarn = { sp = c.warning, undercurl = true },
  DiagnosticUnderlineInfo = { sp = c.unused, undercurl = true },
  DiagnosticUnderlineHint = { sp = c.attribute, underdotted = true },
  DiagnosticVirtualTextError = { fg = c.error, bg = c.error_bg },
  DiagnosticVirtualTextWarn = { fg = c.warning, bg = c.warn_bg },
  DiagnosticVirtualTextInfo = { fg = c.line_nr, bg = c.popup_sel },
  DiagnosticVirtualTextHint = { fg = c.attribute, bg = c.popup_sel },
  DiagnosticUnnecessary = { fg = c.unused },                  -- NOT_USED_ELEMENT_ATTRIBUTES
  DiagnosticDeprecated = { strikethrough = true, sp = c.warning },

  -- LSP
  LspReferenceText = { bg = c.ref_read },                     -- IDENTIFIER_UNDER_CARET
  LspReferenceRead = { bg = c.ref_read },
  LspReferenceWrite = { bg = c.ref_write },                   -- WRITE_SEARCH_RESULT
  LspInlayHint = { fg = c.unused, bg = c.popup, italic = true },
  LspCodeLens = { fg = '#909090', italic = true },            -- ANNOTATIONS_COLOR
  LspCodeLensSeparator = { fg = c.guide_sel },
  LspSignatureActiveParameter = { bg = c.ref_read, bold = true },

  -- Debugger (nvim-dap / dap-virtual-text)
  DapBreakpoint = { fg = c.error },
  DapBreakpointLine = { bg = c.error_bg },                    -- BREAKPOINT_ATTRIBUTES
  DapStopped = { fg = c.yellow },
  DapStoppedLine = { bg = c.exec_bg },                        -- EXECUTIONPOINT_ATTRIBUTES
  NvimDapVirtualText = { fg = c.unused, italic = true },      -- DEBUGGER_INLINED_VALUES
  NvimDapVirtualTextChanged = { fg = '#7a5c43', italic = true }, -- DEBUGGER_INLINED_VALUES_MODIFIED
  NvimDapVirtualTextError = { fg = c.error, italic = true },

  -- Plugins
  TelescopeNormal = { fg = c.fg, bg = c.popup },
  TelescopeBorder = { fg = c.guide_sel, bg = c.popup },
  TelescopeSelection = { bg = c.selection },
  TelescopeMatching = { fg = c.keyword, bold = true },
  TelescopePromptPrefix = { fg = c.keyword },
  TelescopeTitle = { fg = c.bright, bold = true },
  BlinkCmpMenu = { fg = c.fg, bg = c.popup },
  BlinkCmpMenuBorder = { fg = c.guide_sel, bg = c.popup },
  BlinkCmpMenuSelection = { bg = c.selection },
  BlinkCmpLabelMatch = { fg = c.keyword, bold = true },
  BlinkCmpLabelDeprecated = { fg = c.unused, strikethrough = true },
  BlinkCmpDoc = { fg = c.fg, bg = c.popup },
  BlinkCmpDocBorder = { fg = c.guide_sel, bg = c.popup },
  BlinkCmpKind = { fg = c.class },
  WhichKey = { fg = c.keyword },
  WhichKeyGroup = { fg = c.class },
  WhichKeyDesc = { fg = c.fg },
  WhichKeyNormal = { bg = c.popup },
  IblIndent = { fg = c.guide },                               -- INDENT_GUIDE
  IblScope = { fg = c.guide_sel },                            -- SELECTED_INDENT_GUIDE
  FidgetTitle = { fg = c.bright, bold = true },
  FidgetTask = { fg = c.unused },
}

for name, spec in pairs(groups) do
  vim.api.nvim_set_hl(0, name, spec)
end

-- Terminal colors from Rider's console palette (CONSOLE_*_OUTPUT).
local term = {
  '#262626', '#ff5647', '#85c46c', '#d9b72b', '#6c95eb', '#d688d4', '#39cc9b', '#bdbdbd',
  '#666666', '#ff8870', '#adeb96', '#f5d86a', '#add3ff', '#ffbffe', '#7df0c0', '#f0f0f0',
}
for i, col in ipairs(term) do
  vim.g['terminal_color_' .. (i - 1)] = col
end
