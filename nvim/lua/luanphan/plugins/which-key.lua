return function(use)
  use {
    "folke/which-key.nvim",
    event = "VimEnter",
    config = function()
      vim.o.timeout = true
      vim.o.timeoutlen = 300

      require("which-key").setup({
        plugins = {
          spelling = { enabled = true },
        },
        win = {
          border = "single",
        },
      })

      -- Press ? to show all keymaps
      vim.keymap.set("n", "?", function()
        require("which-key").show({ global = true })
      end, { desc = "Show all keymaps" })
    end,
  }
end
