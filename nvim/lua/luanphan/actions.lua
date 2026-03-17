local M = {}

-- Define available actions for the command palette
local actions = {
  {
    name = "Run Go Test (Cursor)",
    action = function()
      require("luanphan.plugins.go").run_go_test_at_cursor()
    end,
  },
  {
    name = "Run Go Test (File)",
    action = function()
      require("luanphan.plugins.go").run_go_test_file()
    end,
  },
  {
    name = "Run Go Test (Package)",
    action = function()
      require("luanphan.plugins.go").run_go_test_package()
    end,
  },
  {
    name = "Format Current File",
    action = function()
      vim.lsp.buf.format({ async = true })
    end,
  },
  {
    name = "Git Status",
    action = function()
      vim.cmd("vertical Git")
    end,
  },
}

---Show a Telescope picker with available actions
function M.show_command_palette()
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions_telescope = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local themes = require("telescope.themes")

  local opts = themes.get_dropdown({
    winblend = 10,
    prompt_title = "Commands",
    results_title = false,
    previewer = false,
    borderchars = { "─", "│", "─", "│", "╭", "╮", "╯", "╰" },
    layout_strategy = "center",
    layout_config = {
      width = 0.4,
      height = 0.3,
    },
  })

  pickers.new(opts, {
    finder = finders.new_table({
      results = actions,
      entry_maker = function(entry)
        return {
          value = entry,
          display = entry.name,
          ordinal = entry.name,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, _)
      actions_telescope.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        actions_telescope.close(prompt_bufnr)
        selection.value.action()
      end)
      return true
    end,
  }):find()
end

-- Set up the command palette keymap
vim.keymap.set("n", "<leader>rt", M.show_command_palette, { desc = "Show commands" })

return M
