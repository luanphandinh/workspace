return {
  {
    "folke/which-key.nvim",
    event = "VimEnter",
    config = function()
      vim.o.timeoutlen = 300

      local wk = require("which-key")
      wk.setup({
        win = {
          border = "single",
        },
      })

      local toggle_icons = require("luanphan.toggle_icons")
      wk.add({
        { "<leader>a", desc = "Toggle agents", icon = { icon = " ", color = "blue" } },
        { "<leader>b", desc = "Toggle file tree", icon = { icon = "󰙅 ", color = "green" } },
        { "<leader>c", group = "Code Actions" },
        { "<leader>e", desc = "Focus file tree", icon = { icon = "󰙅 ", color = "green" } },
        { "<leader>f", group = "Files" },
        { "<leader>g", group = "Git" },
        { "<leader>h", group = "Flow", icon = { icon = "󰛢 ", color = "azure" } },
        { "<leader>k", group = "Editor" },
        { "<leader>r", group = "Run", icon = { icon = " ", color = "green" } },
        { "<leader>s", group = "Settings", icon = { icon = " ", color = "yellow" } },
        { "<leader>sa", group = "Agent" },
        { "<leader>sr", group = "Restart", icon = { icon = " ", color = "cyan" } },
        { "<leader>-", group = "Toggle" },
        { "<leader>w", group = "Workspace", icon = { icon = "󰍹 ", color = "cyan" } },
        { "<leader>-1", desc = "Live grep case sensitivity", icon = toggle_icons.live_grep_case_sensitive },
        { "<leader>-2", desc = "Live grep regex", icon = toggle_icons.live_grep_regex },
        { "<leader>-b", desc = "Line blame", icon = toggle_icons.line_blame, cond = function()
          return toggle_icons.mapping_exists("<leader>-b")
        end },
        { "<leader>-c", desc = "Copilot", icon = toggle_icons.copilot },
        { "<leader>-d", desc = "File diff", icon = toggle_icons.file_diff },
        { "<leader>-D", desc = "Word diff", icon = toggle_icons.word_diff, cond = function()
          return toggle_icons.mapping_exists("<leader>-D")
        end },
        { "<leader>-t", desc = "Terminal", icon = toggle_icons.terminal },
        { "<leader>-w", desc = "Word wrap (current window)", icon = toggle_icons.word_wrap },
        { "<leader>-W", desc = "Word wrap (all windows)", icon = toggle_icons.word_wrap },
        { "<leader>sl", desc = "Terminal reference links", icon = toggle_icons.terminal_reference_links },
      })

      -- Press ? to show all keymaps
      vim.keymap.set("n", "?", function()
        wk.show({ global = true })
      end, { desc = "Show all keymaps" })
    end,
  },
}
