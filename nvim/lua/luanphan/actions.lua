local M = {}

-- State for gitignore visibility
local show_gitignore = false

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
    name = "Git Pull (Current Branch)",
    action = function()
      vim.notify("Pulling...")
      vim.fn.jobstart({ "git", "pull" }, {
        stdout_buffered = true,
        stderr_buffered = true,
        on_exit = function(_, code)
          vim.schedule(function()
            if code == 0 then
              vim.notify("Pull successful")
            else
              vim.notify("Pull failed (exit " .. code .. ")", vim.log.levels.ERROR)
            end
          end)
        end,
      })
    end,
  },
  {
    name = "Git Push (Current Branch)",
    action = function()
      vim.notify("Pushing...")
      vim.fn.jobstart({ "git", "push", "origin", "HEAD" }, {
        stdout_buffered = true,
        stderr_buffered = true,
        on_exit = function(_, code)
          vim.schedule(function()
            if code == 0 then
              vim.notify("Push successful")
            else
              vim.notify("Push failed (exit " .. code .. ")", vim.log.levels.ERROR)
            end
          end)
        end,
      })
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
  {
    name = "Toggle Gitignore (Tree & Telescope)",
    action = function()
      show_gitignore = not show_gitignore

      -- Reconfigure nvim-tree filters
      require("nvim-tree").setup({
        filters = {
          git_ignored = not show_gitignore,
        },
      })
      require("nvim-tree.api").tree.reload()

      -- Update telescope to include/exclude gitignored files
      require("telescope").setup({
        defaults = {
          vimgrep_arguments = show_gitignore
              and { "rg", "--color=never", "--no-heading", "--with-filename", "--line-number", "--column", "--smart-case", "--hidden", "--no-ignore" }
              or { "rg", "--color=never", "--no-heading", "--with-filename", "--line-number", "--column", "--smart-case", "--hidden" },
        },
        pickers = {
          find_files = {
            hidden = true,
            find_command = show_gitignore
                and { "rg", "--files", "--hidden", "--no-ignore" }
                or { "rg", "--files", "--hidden" },
          },
        },
      })

      print("Gitignore visibility: " .. (show_gitignore and "ON" or "OFF"))
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
