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
      -- Lua patterns for string.find on paths (see :help lua-patterns)
      local ignore_dot_git = { "%.git[/\\]" }
      local grep_opts = require("luanphan.telescope_grep_opts")

      require("telescope").setup({
        defaults = {
          file_ignore_patterns = ignore_dot_git,
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
            hidden = true, -- show dotfiles
            file_ignore_patterns = ignore_dot_git,
          },
          live_grep = {
            -- Used by |luanphan.telescope_grep_opts.live_grep()| (|g/|). Not applied by :Telescope live_grep alone.
            additional_args = grep_opts.additional_args,
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
