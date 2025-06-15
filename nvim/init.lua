-- Auto-install packer if not installed
local ensure_packer = function()
  local fn = vim.fn
  local install_path = fn.stdpath("data") .. "/site/pack/packer/start/packer.nvim"
  if fn.empty(fn.glob(install_path)) > 0 then
    fn.system({
      "git",
      "clone",
      "--depth",
      "1",
      "https://github.com/wbthomason/packer.nvim",
      install_path,
    })
    vim.cmd([[packadd packer.nvim]])
    return true
  end
  return false
end

ensure_packer()

-- Plugins
require("packer").startup(function(use)
  use "wbthomason/packer.nvim"
  use "nvim-lua/plenary.nvim"

  require("luanphan.plugins.nvim-tree")(use)
  require("luanphan.plugins.treesitter")(use)
  require("luanphan.plugins.telescope")(use)
  require("luanphan.plugins.lsp")(use)
  require("luanphan.plugins.gitsigns")(use)
  require("luanphan.plugins.harpoon")(use)
  require("luanphan.plugins.editor")(use)
  require("luanphan.plugins.agent")(use)

  require("luanphan.keymap.keymap")
end)

-- Use 2 spaces for Lua files
vim.api.nvim_create_autocmd("FileType", {
  pattern = "lua",
  callback = function()
    vim.bo.shiftwidth = 2   -- indent size
    vim.bo.tabstop = 2      -- tab width
    vim.bo.softtabstop = 2  -- how many spaces a <Tab> feels like
    vim.bo.expandtab = true -- use spaces instead of tabs
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  pattern = "go",
  callback = function()
    vim.bo.shiftwidth = 4    -- indent size
    vim.bo.tabstop = 4       -- tab width
    vim.bo.softtabstop = 4   -- how many spaces a <Tab> feels like
    vim.bo.expandtab = false -- use spaces instead of tabs
  end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    for _, client in pairs(vim.lsp.get_clients()) do
      client.stop()
    end
  end,
})
