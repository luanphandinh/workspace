return function(use)
  use {
    "nvim-treesitter/nvim-treesitter",
    run = ":TSUpdate", -- or `run` if still using older packer
    config = function()
      require("nvim-treesitter.configs").setup({
        ensure_installed = { "c", "lua", "vim", "vimdoc", "json", "yaml", "go", "luadoc", "markdown" },
        sync_install = false,
        auto_install = true,
        highlight = {
          enable = true,
          additional_vim_regex_highlighting = false
        },
        indent = {
          enable = true
        },
      })
    end
  }
end
