return function(use)
  use({
    "yetone/avante.nvim",
    build = "make",
    lazy = false,
    version = false,
    BUILD_FROM_SOURCE = true,
    event = { "BufReadPre", "BufNewFile" }, -- lazy load when opening a file
    config = function()
      require("avante_lib").load()
      require("avante").setup({
        provider = "ollama",
        providers = {
          ollama = {
            endpoint = "http://localhost:11434",
            model = "deepseek-coder:6.7b",
            api_key_name = "",
          },
        }
      })
    end,
    requires = {
      "nvim-treesitter/nvim-treesitter",
      "stevearc/dressing.nvim",
      "nvim-lua/plenary.nvim",
      "MunifTanjim/nui.nvim",
      --- The below dependencies are optional,
      "nvim-tree/nvim-web-devicons", -- or echasnovski/mini.icons
      "HakonHarnes/img-clip.nvim",
    },
  })
end
