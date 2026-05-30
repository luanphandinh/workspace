return {
  {
    "folke/which-key.nvim",
    event = "VimEnter",
    config = function()
      vim.o.timeout = true
      vim.o.timeoutlen = 300

      local wk = require("which-key")
      wk.setup({
        plugins = {
          spelling = { enabled = true },
        },
        win = {
          border = "single",
        },
      })

      wk.add({
        { "<leader>f", group = "Files" },
        { "<leader>g", group = "Git" },
        { "<leader>h", group = "Harpoon" },
        { "<leader>t", group = "Toggle" },
      })

      -- Press ? to show all keymaps
      vim.keymap.set("n", "?", function()
        wk.show({ global = true })
      end, { desc = "Show all keymaps" })
    end,
  },
}
