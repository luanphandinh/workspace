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
  require("luanphan.file_configs.go")
  require("luanphan.file_configs.lua")
end)
