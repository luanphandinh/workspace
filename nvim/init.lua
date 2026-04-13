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
  require("luanphan.plugins.copilot")(use)
  require("luanphan.plugins.lsp")(use)
  require("luanphan.plugins.gitsigns")(use)
  require("luanphan.plugins.git-diff")(use)
  require("luanphan.plugins.harpoon")(use)
  require("luanphan.plugins.editor")(use)
  require("luanphan.plugins.terminal")(use)
  require("luanphan.plugins.multi-cursor")(use)
  require("luanphan.plugins.which-key")(use)

  require("luanphan.keymap.keymap")
  require("luanphan.cursor_agent").setup()
  require("luanphan.claude_agent").setup()
  require("luanphan.file_configs.go")
  require("luanphan.file_configs.lua")
  require("luanphan.file_configs.json")
  require("luanphan.actions")

  -- Custom private plugins (gitignored)
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
end)
