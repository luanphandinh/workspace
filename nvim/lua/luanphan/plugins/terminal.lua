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
        -- Keep the pane after the shell job exits so output stays visible (scroll with Esc then j/k).
        close_on_exit = false,
        auto_scroll = true,
      })

      -- Toggle terminal on the right
      vim.keymap.set("n", "<leader>tt", "<cmd>ToggleTerm<cr>", { desc = "Toggle terminal" })

      -- Terminal mode mappings
      function _G.set_terminal_keymaps()
        local opts = { buffer = 0 }
        vim.keymap.set("t", "<esc>", [[<c-\><c-n>]], opts)
      end

      -- Enter terminal mode only when a terminal buffer is first created — not on every BufEnter.
      -- Otherwise each refocus runs |startinsert|, so j/k go to a dead PTY after `go test` exits instead
      -- of moving in normal mode in the scrollback.
      vim.api.nvim_create_autocmd("TermOpen", {
        pattern = "term://*",
        callback = function()
          vim.defer_fn(function()
            if vim.bo.buftype == "terminal" then
              vim.cmd("startinsert")
            end
          end, 10)
        end,
      })

      vim.cmd("autocmd! TermOpen * lua set_terminal_keymaps()")
    end,
  }
end
