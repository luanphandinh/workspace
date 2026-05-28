return {
  -- Gruvbox theme
  {
    "ellisonleao/gruvbox.nvim",
    config = function()
      require("gruvbox").setup({
        bold = false,
      })
      vim.o.background = "dark"
      vim.cmd([[colorscheme gruvbox]])
    end,
  },

  -- auto pair brackets
  {
    "windwp/nvim-autopairs",
    config = function()
      require("nvim-autopairs").setup({
        check_ts = true, -- enable Treesitter integration for smarter pairing
      })
    end,
  },

  -- comment plugin
  {
    "numToStr/Comment.nvim",
    config = function()
      require("Comment").setup()
    end,
  },
}
