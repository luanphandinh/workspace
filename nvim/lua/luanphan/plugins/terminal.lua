return function(use)
  -- Toggleable terminal overlay
  use {
    "akinsho/toggleterm.nvim",
    config = function()
      require("toggleterm").setup({
        size = 20,
        direction = "float", -- floating overlay
        shade_terminals = false,
        persist_size = true,
        persist_mode = true,
        close_on_exit = true, -- close on Ctrl+D
        auto_scroll = true,
        float_opts = {
          border = "curved",
          winblend = 0,
        },
      })

      -- Toggle terminal with leader+t
      vim.keymap.set("n", "<leader>t", "<cmd>ToggleTerm<cr>", { desc = "Toggle terminal" })

      -- Terminal mode mappings
      function _G.set_terminal_keymaps()
        local opts = { buffer = 0 }
        -- Ctrl+D and Ctrl+C work naturally in terminal
        -- Escape to exit terminal mode
        vim.keymap.set("t", "<esc>", [[<c-\><c-n>]], opts)
      end

      vim.cmd("autocmd! TermOpen * lua set_terminal_keymaps()")
    end,
  }
end
