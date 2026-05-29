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

local specs = {
  "nvim-lua/plenary.nvim",
  { import = "luanphan.plugins.nvim-tree" },
  { import = "luanphan.plugins.treesitter" },
  { import = "luanphan.plugins.telescope" },
  { import = "luanphan.plugins.actions" },
  { import = "luanphan.plugins.copilot" },
  { import = "luanphan.plugins.lsp" },
  { import = "luanphan.plugins.gitsigns" },
  { import = "luanphan.plugins.git-diff" },
  { import = "luanphan.plugins.worktree" },
  { import = "luanphan.plugins.harpoon" },
  { import = "luanphan.plugins.editor" },
  { import = "luanphan.plugins.file-configs" },
  { import = "luanphan.plugins.terminal" },
  { import = "luanphan.plugins.agents" },
  { import = "luanphan.plugins.multi-cursor" },
  { import = "luanphan.plugins.which-key" },
}

local function add_specs(extra_specs)
  if extra_specs then
    table.insert(specs, extra_specs)
  end
end

local internal_path = vim.fn.stdpath("config") .. "/lua/luanphan/internal"
if vim.fn.isdirectory(internal_path) == 1 then
  for _, file in ipairs(vim.fn.glob(internal_path .. "/*.lua", false, true)) do
    local module = file:match(".*/internal/(.+)%.lua$")
    if module then
      local ok, mod = pcall(require, "luanphan.internal." .. module)
      if ok and type(mod) == "function" then
        local internal_specs, use = require("luanphan.lazy_use").collect()
        mod(use)
        add_specs(internal_specs)
      elseif ok and type(mod) == "table" then
        add_specs(mod)
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
require("luanphan.qf_replace").setup()
