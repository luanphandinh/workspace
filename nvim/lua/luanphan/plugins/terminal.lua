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
        persist_mode = false,
        close_on_exit = true,
        auto_scroll = true,
      })

      -- Toggle terminal on the right
      vim.keymap.set("n", "<leader>tt", "<cmd>ToggleTerm<cr>", { desc = "Toggle terminal" })

      -- Terminal mode mappings
      function _G.set_terminal_keymaps()
        local opts = { buffer = 0 }
        vim.keymap.set("t", "<esc>", [[<c-\><c-n>]], opts)
      end

      -- Auto enter insert mode when entering terminal buffer
      vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
        pattern = "term://*",
        callback = function()
          vim.defer_fn(function()
            vim.cmd("startinsert")
          end, 10)
        end,
      })

      vim.cmd("autocmd! TermOpen * lua set_terminal_keymaps()")
    end,
  }
end
