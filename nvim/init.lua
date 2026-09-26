vim.g.mapleader = " "
vim.g.maplocalleader = " "

local neovide_configured = false

local function configure_neovide()
  if neovide_configured or not vim.g.neovide then
    return
  end

  neovide_configured = true
  vim.g.neovide_scale_factor = 1.0

  local function change_scale(multiplier)
    local scale = vim.g.neovide_scale_factor * multiplier
    vim.g.neovide_scale_factor = math.max(0.5, math.min(3.0, scale))
  end

  local modes = { "n", "i", "v", "t" }
  for _, key in ipairs({ "<D-=>", "<D-+>" }) do
    vim.keymap.set(modes, key, function()
      change_scale(1.1)
    end, { desc = "Zoom in" })
  end
  vim.keymap.set(modes, "<D-->", function()
    change_scale(1 / 1.1)
  end, { desc = "Zoom out" })
  vim.keymap.set(modes, "<D-0>", function()
    vim.g.neovide_scale_factor = 1.0
  end, { desc = "Reset zoom" })

  vim.keymap.set({ "n", "i", "v", "c", "t" }, "<D-v>", function()
    vim.api.nvim_paste(vim.fn.getreg("+"), true, -1)
  end, { silent = true, desc = "Paste" })
end

configure_neovide()
vim.api.nvim_create_autocmd("UIEnter", { callback = configure_neovide })

if vim.env.SSH_TTY or vim.env.SSH_CONNECTION then
  local tmux_copy = vim.fn.expand("~/bin/tmux-copy-osc52")
  if vim.env.TMUX and vim.fn.executable(tmux_copy) == 1 then
    vim.g.clipboard = {
      name = "OSC52 through tmux client",
      copy = {
        ["+"] = { tmux_copy },
        ["*"] = { tmux_copy },
      },
      paste = {
        ["+"] = { "tmux", "save-buffer", "-" },
        ["*"] = { "tmux", "save-buffer", "-" },
      },
      cache_enabled = 0,
    }
  else
    vim.g.clipboard = "osc52"
  end
end

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
  { import = "luanphan.plugins.file-configs" },
  { import = "luanphan.plugins.qf-replace" },
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

require("luanphan.plugins.treesitter").setup()
require("luanphan.keymap.keymap")
