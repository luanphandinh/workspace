return function(use)
  use {
    "folke/which-key.nvim",
    event = "VimEnter",
    config = function()
      local wk = require("which-key")

      wk.setup({
        plugins = {
          marks = true,
          registers = true,
          spelling = { enabled = true, suggestions = 20 },
          presets = {
            operators = true,
            motions = true,
            text_objects = true,
            windows = true,
            nav = true,
            z = true,
            g = true,
          },
        },
        icons = {
          breadcrumb = "»",
          separator = "➜",
          group = "+",
        },
        window = {
          border = "single",
          position = "bottom",
          margin = { 1, 0, 1, 0 },
          padding = { 2, 2, 2, 2 },
        },
        layout = {
          height = { min = 4, max = 25 },
          width = { min = 20, max = 50 },
          spacing = 3,
          align = "left",
        },
      })

      -- Register keybindings groups
      wk.register({
        ["<leader>"] = {
          f = { name = "+find" },
          g = { name = "+git" },
          h = { name = "+hunk" },
          t = { name = "+toggle" },
          r = { name = "+reload" },
          a = { name = "+claude" },
        },
      })

      -- Press ? to show all keymaps
      wk.register({
        ["?"] = { function() wk.show({ global = true }) end, "Show all keymaps" },
      })
    end,
  }
end
