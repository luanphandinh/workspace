return function(use)
  -- Toggleable terminal
  use {
    "akinsho/toggleterm.nvim",
    config = function()
      require("toggleterm").setup({
        size = 100,
        direction = "vertical", -- opens on the right
        shade_terminals = false,
        persist_size = true,
        persist_mode = true,
        close_on_exit = true,
        auto_scroll = true,
      })

      -- Toggle terminal on the right
      vim.keymap.set("n", "<leader>t", "<cmd>ToggleTerm<cr>", { desc = "Toggle terminal" })

      -- Terminal mode mappings
      function _G.set_terminal_keymaps()
        local opts = { buffer = 0 }
        vim.keymap.set("t", "<esc>", [[<c-\><c-n>]], opts)
      end

      vim.cmd("autocmd! TermOpen * lua set_terminal_keymaps()")
    end,
  }
end
