require('core.keymaps')  -- leader keys + general mappings
require('core.options')  -- editor settings
require('core.autocmds') -- autocommands
require('core.lazy')     -- plugin manager bootstrap + plugin loading
require('core.reload').setup() -- apply config edits to the running Neovim (:ConfigReload)
require('core.ui_select').setup() -- choices in a Telescope list instead of a numbered prompt
require('core.compiledb').setup() -- compile_commands.json for clangd outside Windows UE (CMake, Meson, Bear, UBT)
