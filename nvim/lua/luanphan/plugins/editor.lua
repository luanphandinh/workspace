return {
  -- Gruvbox theme
  {
    "ellisonleao/gruvbox.nvim",
    config = function()
      local function disable_italic_highlights()
        for name, _ in pairs(vim.api.nvim_get_hl(0, {})) do
          local ok, highlight = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
          if ok and highlight.italic then
            highlight.italic = false
            vim.api.nvim_set_hl(0, name, highlight)
          end
        end
      end

      vim.api.nvim_create_autocmd("ColorScheme", {
        group = vim.api.nvim_create_augroup("luanphan_no_italic_highlights", { clear = true }),
        callback = disable_italic_highlights,
      })

      require("gruvbox").setup({
        bold = false,
        italic = {
          strings = false,
          emphasis = false,
          comments = false,
          operators = false,
          folds = false,
        },
      })
      vim.o.background = "dark"
      vim.cmd([[colorscheme gruvbox]])
      disable_italic_highlights()
    end,
  },

  -- auto pair brackets
  {
    "windwp/nvim-autopairs",
    event = "InsertEnter",
    config = function()
      require("nvim-autopairs").setup({
        check_ts = true, -- enable Treesitter integration for smarter pairing
      })
    end,
  },

  -- comment plugin
  {
    "numToStr/Comment.nvim",
    keys = {
      { "gc", mode = { "n", "x" } },
      { "gcc", mode = "n" },
      { "gb", mode = { "n", "x" } },
      { "gbc", mode = "n" },
      { "gco", mode = "n" },
      { "gcO", mode = "n" },
      { "gcA", mode = "n" },
    },
    config = function()
      require("Comment").setup()
    end,
  },
}
