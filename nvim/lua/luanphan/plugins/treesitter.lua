---@diagnostic disable: missing-fields
return function(use)
  use {
    "nvim-treesitter/nvim-treesitter",
    run = ":TSUpdate", -- or `run` if still using older packer
    config = function()
      -- Enable folding with treesitter
      vim.opt.foldmethod = "expr"
      vim.opt.foldexpr = "nvim_treesitter#foldexpr()"
      vim.opt.foldlevel = 99  -- Start with folds open

      require("nvim-treesitter.configs").setup({
        sync_install = false,
        auto_install = true,
        highlight = {
          enable = true,
          additional_vim_regex_highlighting = false
        },
        indent = {
          enable = true
        },
        ensure_installed = {
          "go",
          "lua",
          "c",
          "vim",
          "vimdoc",
          "json",
          "yaml",
          "luadoc",
          "markdown",
        },
      })
    end
  }
end
