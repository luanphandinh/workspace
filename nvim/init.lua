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

  -- Gruvbox theme
  use {
    "ellisonleao/gruvbox.nvim",
    config = function()
      require("gruvbox").setup({
        bold = false,
      })
      vim.o.background = "dark"
      vim.cmd([[colorscheme gruvbox]])
    end,
  }

  -- auto pair brackets
  use {
    "windwp/nvim-autopairs",
    config = function()
      require("nvim-autopairs").setup({
        check_ts = true, -- enable Treesitter integration for smarter pairing
      })
    end
  }

  -- comment plugin
  use {
    "numToStr/Comment.nvim",
    config = function()
      require("Comment").setup()
    end
  }


  -- Avante + Ollama
  use({
    "yetone/avante.nvim",
    build = "make",
    lazy = false,
    version = false,
    BUILD_FROM_SOURCE = true,
    event = { "BufReadPre", "BufNewFile" }, -- lazy load when opening a file
    config = function()
      require("avante_lib").load()
      require("avante").setup({
        provider = "ollama",
        providers = {
          ollama = {
            endpoint = "http://localhost:11434",
            model = "deepseek-coder:6.7b",
            api_key_name = "",
          },
        }
      })
    end,
    requires = {
      "nvim-treesitter/nvim-treesitter",
      "stevearc/dressing.nvim",
      "nvim-lua/plenary.nvim",
      "MunifTanjim/nui.nvim",
      --- The below dependencies are optional,
      "nvim-tree/nvim-web-devicons", -- or echasnovski/mini.icons
      "HakonHarnes/img-clip.nvim",
    },
  })
end)

-- Basic keymaps and options
vim.g.mapleader = " "
vim.o.number = true
vim.o.relativenumber = true
vim.o.swapfile = false
vim.o.backup = false
vim.o.undodir = os.getenv("HOME") .. "/.vim/undodir"
vim.o.undofile = true
vim.o.hlsearch = false
vim.o.incsearch = true
-- Display options
vim.o.cursorline = true
vim.o.scrolloff = 8
vim.o.signcolumn = "yes" -- always show the signcolumn on the left side
-- keymaps
vim.keymap.set("n", "n", "nzzzv", { noremap = true, silent = true })
vim.keymap.set("n", "N", "nzzzv", { noremap = true, silent = true })

vim.keymap.set("n", "<C-d>", "<C-d>zz", { noremap = true, silent = true })
vim.keymap.set("n", "<C-u>", "<C-u>zz", { noremap = true, silent = true })
vim.keymap.set("n", "J", "mzJ`z", { noremap = true, silent = true })
vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv")
vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv")

vim.keymap.set("n", "<leader>y", "\"+y")
vim.keymap.set("v", "<leader>y", "\"+y")

vim.keymap.set("n", "<leader>d", "\"_d")
vim.keymap.set("v", "<leader>d", "\"_d")
vim.keymap.set("x", "<leader>p", "\"_dP")

vim.keymap.set("n", "<C-f>", "<cmd>slient !tmux neww tmux-sessionizer<CR>")
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

vim.keymap.set("n", "<leader>of", function()
  require("telescope.builtin").lsp_document_symbols({
    symbols = { "Function", "Method" },
    symbol_width = 80,
    previewer = false,
    layout_config = {
      width = 0.5,
      height = 0.5,
    },
  })
end, { noremap = true, silent = true })

vim.keymap.set("n", "<leader>d", function()
  vim.diagnostic.open_float(nil, { focus = false })
end, { desc = "Show diagnostic at line" })

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    for _, client in pairs(vim.lsp.get_clients()) do
      client.stop()
    end
  end,
})
