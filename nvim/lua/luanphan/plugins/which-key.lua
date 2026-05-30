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

      local toggle_icons = require("luanphan.toggle_icons")
      wk.add({
        { "<leader>a", group = "Cursor", icon = { icon = "󰆿 ", color = "blue" } },
        { "<leader>b", desc = "Toggle NvimTree", icon = { icon = "󰙅 ", color = "green" } },
        { "<leader>c", group = "Code Actions" },
        { "<leader>e", desc = "Focus NvimTree", icon = { icon = "󰙅 ", color = "green" } },
        { "<leader>f", group = "Files" },
        { "<leader>g", group = "Git" },
        { "<leader>h", group = "Harpoon", icon = { icon = "󰛢 ", color = "azure" } },
        { "<leader>k", group = "Editor" },
        { "<leader>r", group = "Restart", icon = { icon = " ", color = "cyan" } },
        { "<leader>t", group = "Toggle" },
        { "<leader>x", group = "Claude", icon = { icon = " ", color = "green" } },
        { "<leader>t1", desc = "Live grep case sensitivity", icon = toggle_icons.live_grep_case_sensitive },
        { "<leader>t2", desc = "Live grep regex", icon = toggle_icons.live_grep_regex },
        { "<leader>tb", desc = "Line blame", icon = toggle_icons.line_blame, cond = function()
          return toggle_icons.mapping_exists("<leader>tb")
        end },
        { "<leader>tc", desc = "Copilot", icon = toggle_icons.copilot },
        { "<leader>td", desc = "File diff", icon = toggle_icons.file_diff },
        { "<leader>tt", desc = "Terminal", icon = toggle_icons.terminal },
        { "<leader>tw", desc = "Word diff", icon = toggle_icons.word_diff, cond = function()
          return toggle_icons.mapping_exists("<leader>tw")
        end },
        { "<leader>tW", desc = "Word wrap (window-local)", icon = toggle_icons.word_wrap },
      })

      -- Press ? to show all keymaps
      vim.keymap.set("n", "?", function()
        wk.show({ global = true })
      end, { desc = "Show all keymaps" })
    end,
  },
}
