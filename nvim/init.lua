-- Auto-install packer if not installed
local ensure_packer = function()
  local fn = vim.fn
  local install_path = fn.stdpath("data") .. "/site/pack/packer/start/packer.nvim"
  if fn.empty(fn.glob(install_path)) > 0 then
    fn.system({
      "git",
      "clone",
      "--depth",
      "1",
      "https://github.com/wbthomason/packer.nvim",
      install_path,
    })
    vim.cmd([[packadd packer.nvim]])
    return true
  end
  return false
end

ensure_packer()

-- Plugins
require("packer").startup(function(use)
  use "wbthomason/packer.nvim"
  use "nvim-lua/plenary.nvim"

  require("luanphan.plugins.nvim-tree")(use)
  require("luanphan.plugins.treesitter")(use)
  require("luanphan.plugins.telescope")(use)
  require("luanphan.plugins.lsp")(use)
  require("luanphan.plugins.gitsigns")(use)
  require("luanphan.plugins.harpoon")(use)
  require("luanphan.plugins.editor")(use)
  require("luanphan.plugins.agent")(use)

  require("luanphan.keymap.keymap")
  require("luanphan.file_configs.go")
  require("luanphan.file_configs.lua")
  local actions = {
    {
      name = "Run Go Test",
      action = function()
        local go = require("luanphan.plugins.go")
        go.run_go_test_at_cursor()
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

  local function show_command_palette()
    local pickers           = require("telescope.pickers")
    local finders           = require("telescope.finders")
    local conf              = require("telescope.config").values
    local actions_telescope = require("telescope.actions")
    local action_state      = require("telescope.actions.state")
    local themes            = require("telescope.themes")

    -- use a dropdown theme + custom size
    local opts              = themes.get_dropdown({
      winblend        = 10,    -- transparency; 0 = solid
      prompt_title    = "Shortcut Commands",
      results_title   = false, -- hide the “Results” title
      previewer       = false, -- no preview
      borderchars     = { "─", "│", "─", "│", "╭", "╮", "╯", "╰" },
      layout_strategy = "center",
      layout_config   = {
        width  = 0.4, -- 40 % of screen width
        height = 0.3, -- 30 % of screen height
      },
    })

    pickers.new(opts, {
      finder = finders.new_table {
        results = actions,
        entry_maker = function(entry)
          return {
            value = entry,
            display = entry.name,
            ordinal = entry.name,
          }
        end,
      },
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

  vim.keymap.set("n", "<leader>rt", show_command_palette, { desc = "Show shortcut commands" })
end)
