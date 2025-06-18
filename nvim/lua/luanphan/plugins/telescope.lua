return function(use)
  -- use {
  --   'nvim-telescope/telescope-fzf-native.nvim',
  --   run = 'cmake -S. -Bbuild -DCMAKE_BUILD_TYPE=Release && cmake --build build --config Release'
  -- }
  use {
    'nvim-telescope/telescope-fzy-native.nvim',
    run = 'make',
    config = function()
      require('telescope').load_extension('fzy_native')
    end,
  }

  use {
    "nvim-telescope/telescope.nvim",
    requires = { "nvim-lua/plenary.nvim" },
    config = function()
      require("telescope").setup({
        defaults = {
          sorting_strategy = "ascending",
          layout_config = {
            prompt_position = "top",
            preview_cutoff = 1,
          },
          preview = {
            treesitter = false,
          },
          file_sorter = require('telescope.sorters').get_fzy_sorter,
        },
        extensions = {
          fzf = {
            fuzzy = true,                   -- enable fuzzy matching
            override_generic_sorter = true, -- override the default sorter
            override_file_sorter = true,
            case_mode = "smart_case",
          }
        }
      })
      -- require('telescope').load_extension('fzf')
      vim.keymap.set("n", "<leader>f", "<cmd>Telescope find_files<cr>")
      vim.keymap.set("n", "g/", "<cmd>Telescope live_grep<cr>")
    end,
  }
end
