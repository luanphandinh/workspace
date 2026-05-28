local function find_files()
  require("telescope.builtin").find_files()
end

local function live_grep()
  require("luanphan.telescope_grep_opts").live_grep()
end

local function buffers()
  require("telescope.builtin").buffers()
end

local function document_symbols()
  require("telescope.builtin").lsp_document_symbols({
    previewer = false,
    symbol_width = 80,
    layout_strategy = "vertical",
    layout_config = {
      width = 0.5,
      height = 0.6,
    },
  })
end

local function filetypes()
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local options = { "json", "sql", "txt", "md", "go", "lua", "python", "javascript", "yaml", "html", "css" }

  pickers
    .new({}, {
      prompt_title = "Set Filetype",
      finder = finders.new_table({ results = options }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, _)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            vim.bo.filetype = selection[1]
          end
        end)
        return true
      end,
    })
    :find()
end

return {
  -- {
  --   'nvim-telescope/telescope-fzf-native.nvim',
  --   build = 'cmake -S. -Bbuild -DCMAKE_BUILD_TYPE=Release && cmake --build build --config Release'
  -- }
  {
    "nvim-telescope/telescope.nvim",
    cmd = "Telescope",
    keys = {
      { "<leader>p", find_files, desc = "Telescope: find files" },
      { "g/", live_grep, desc = "Telescope: live grep" },
      { "<leader>lf", buffers, desc = "Telescope: buffers" },
      { "gs", document_symbols, desc = "Telescope: document symbols" },
      { "<leader>ft", filetypes, desc = "Telescope: set filetype" },
      {
        "<leader>cp",
        function()
          require("luanphan.actions").show_command_palette()
        end,
        desc = "Show commands",
      },
    },
    dependencies = {
      "nvim-lua/plenary.nvim",
      {
        "nvim-telescope/telescope-fzy-native.nvim",
        build = "make",
      },
    },
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
            find_command = { "rg", "--files", "--hidden", "--follow" },
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
      pcall(require("telescope").load_extension, "fzy_native")
    end,
  },
}
