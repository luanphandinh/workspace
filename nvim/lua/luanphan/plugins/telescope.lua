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
          -- Performance optimizations
          cache_picker = {
            num_pickers = 5,
            limit_entries = 1000,
          },
          path_display = { "truncate" },  -- faster than full path
          winblend = 0,  -- disable transparency for faster rendering
        },
        pickers = {
          find_files = {
            hidden = true,  -- show dotfiles
          },
          live_grep = {
            additional_args = function()
              return { "--hidden" }  -- search hidden files in live_grep
            end,
          },
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
    end,
  }
end
