local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"

-- Initialize lazy_bootstrap
LazyBootstrap = not vim.loop.fs_stat(lazypath)

-- Check if lazy.nvim is installed
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", -- latest stable release
    lazypath,
  })
end

vim.opt.rtp:prepend(lazypath)

Plugins = require('plugins')
General = require('general')
Debug = require('uidebug')
Keybindings = require('keybindings')
Serversetup = require('serversetup')
Autocompletion = require('autocompletion')
