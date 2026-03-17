return function(use)
  use {
    "coder/claudecode.nvim",
    requires = { "folke/snacks.nvim" },
    config = function()
      require("claudecode").setup({
        terminal = {
          split_side = "right",
          split_width_percentage = 0.4, -- 40% of window width
        },
      })
    end,
  }
end
