vim.g.mapleader = " "
vim.g.maplocalleader = " "

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

local specs, use = require("luanphan.lazy_use").collect()
use("nvim-lua/plenary.nvim")

require("luanphan.plugins.nvim-tree")(use)
require("luanphan.plugins.treesitter")(use)
require("luanphan.plugins.telescope")(use)
require("luanphan.plugins.copilot")(use)
require("luanphan.plugins.lsp")(use)
require("luanphan.plugins.gitsigns")(use)
require("luanphan.plugins.git-diff")(use)
require("luanphan.plugins.worktree")(use)
require("luanphan.plugins.harpoon")(use)
require("luanphan.plugins.editor")(use)
require("luanphan.plugins.terminal")(use)
require("luanphan.plugins.multi-cursor")(use)
require("luanphan.plugins.which-key")(use)

local internal_path = vim.fn.stdpath("config") .. "/lua/luanphan/internal"
if vim.fn.isdirectory(internal_path) == 1 then
  for _, file in ipairs(vim.fn.glob(internal_path .. "/*.lua", false, true)) do
    local module = file:match(".*/internal/(.+)%.lua$")
    if module then
      local ok, mod = pcall(require, "luanphan.internal." .. module)
      if ok and type(mod) == "function" then
        mod(use)
      end
    end
  end
end

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

require("luanphan.keymap.keymap")
require("luanphan.cursor_agent").setup()
require("luanphan.claude_agent").setup()
require("luanphan.codex_agent").setup()
require("luanphan.file_configs.go")
require("luanphan.file_configs.lua")
require("luanphan.file_configs.json")
require("luanphan.actions")
require("luanphan.qf_replace").setup()
