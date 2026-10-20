vim.g.mapleader = " "
vim.g.maplocalleader = " "

require("luanphan.remote_tunnel").setup()
require("luanphan.neovide").setup()
require("luanphan.ssh_clipboard").setup()

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
    }, true, {})
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

local specs = {
  { import = "luanphan.plugins.nvim-tree" },
  { import = "luanphan.plugins.telescope" },
  { import = "luanphan.plugins.actions" },
  { import = "luanphan.plugins.copilot" },
  { import = "luanphan.plugins.lsp" },
  { import = "luanphan.plugins.gitsigns" },
  { import = "luanphan.plugins.git-diff" },
  { import = "luanphan.plugins.worktree" },
  { import = "luanphan.plugins.flow" },
  { import = "luanphan.plugins.editor" },
  { import = "luanphan.plugins.markdown" },
  { import = "luanphan.plugins.terminal" },
  { import = "luanphan.plugins.agents" },
  { import = "luanphan.plugins.multi-cursor" },
  { import = "luanphan.plugins.which-key" },
}

require("lazy").setup(specs, {
  defaults = {
    lazy = false,
  },
  checker = {
    enabled = false,
  },
  change_detection = {
    notify = false,
  },
  install = {
    colorscheme = { "gruvbox", "habamax" },
  },
})

require("luanphan.plugins.treesitter").setup()
require("luanphan.keymap.keymap")
