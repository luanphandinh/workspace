return function(use)
  -- Global git diff viewer
  use {
    "sindrets/diffview.nvim",
    event = "CmdlineEnter", -- lazy load when entering command mode
    requires = "nvim-lua/plenary.nvim",
    config = function()
      require("diffview").setup({
        view = {
          default = {
            layout = "diff2_horizontal",
          },
        },
        file_panel = {
          win_config = {
            width = 35,
          },
        },
        hooks = {
          diff_buf_read = function(bufnr)
            vim.opt_local.wrap = false
            vim.opt_local.list = false
          end,
        },
      })


      -- Close diffview with q in any diffview buffer
      vim.api.nvim_create_autocmd("BufEnter", {
        callback = function()
          local bufname = vim.api.nvim_buf_get_name(0)
          if bufname:match("diffview://") then
            vim.keymap.set("n", "q", "<cmd>DiffviewClose<cr>", { buffer = true, silent = true })
          end
        end,
      })

      -- Git diff globally
      vim.keymap.set("n", "<leader>gdo", "<cmd>DiffviewOpen<cr>", { desc = "Open git diff (all files)" })
      vim.keymap.set("n", "<leader>gdc", "<cmd>DiffviewClose<cr>", { desc = "Close git diff" })
      vim.keymap.set("n", "<leader>gdh", "<cmd>DiffviewFileHistory %<cr>", { desc = "File history (current)" })
      vim.keymap.set("n", "<leader>gdH", "<cmd>DiffviewFileHistory<cr>", { desc = "File history (all)" })
    end,
  }

  -- Git conflict navigation and resolution
  use {
    "akinsho/git-conflict.nvim",
    version = "*",
    event = "BufReadPre",
    config = function()
      require("git-conflict").setup({
        default_mappings = true, -- disable to use custom mappings
        default_commands = true, -- disable to use custom commands
        disable_diagnostics = false,
        highlights = {
          incoming = "DiffAdd",
          current = "DiffText",
        },
      })

      -- Custom keymaps for conflict resolution
      vim.keymap.set("n", "<leader>gco", "<cmd>GitConflictChooseOurs<cr>", { desc = "Choose ours (current)" })
      vim.keymap.set("n", "<leader>gct", "<cmd>GitConflictChooseTheirs<cr>", { desc = "Choose theirs (incoming)" })
      vim.keymap.set("n", "<leader>gcb", "<cmd>GitConflictChooseBoth<cr>", { desc = "Choose both" })
      vim.keymap.set("n", "<leader>gcn", "<cmd>GitConflictNextConflict<cr>", { desc = "Next conflict" })
      vim.keymap.set("n", "<leader>gcp", "<cmd>GitConflictPrevConflict<cr>", { desc = "Previous conflict" })
      vim.keymap.set("n", "<leader>gcl", "<cmd>GitConflictListQf<cr>", { desc = "List conflicts in quickfix" })
    end,
  }
end
