-- noice.nvim — renders the command-line as a floating popup so typing `:`
-- doesn't shrink/grow the buffer area. Works with cmdheight = 0 to fully
-- reclaim the bottom row.
return function(use)
  use {
    "folke/noice.nvim",
    requires = { "MunifTanjim/nui.nvim" },
    config = function()
      require("noice").setup({
        cmdline = {
          enabled = true,
          view = "cmdline_popup",  -- floating popup, centered-ish
        },
        messages = {
          enabled = true,
          view = "notify",
          view_error = "notify",
          view_warn = "notify",
          view_history = "messages",
          view_search = "virtualtext",
        },
        popupmenu = {
          enabled = true,
          backend = "nui",
        },
        notify = {
          enabled = true,
          view = "notify",
        },
        lsp = {
          -- Don't override LSP handlers; user has telescope for code-action
          -- and the floating LspInfo we already wired in plugins/lsp.lua.
          override = {
            ["vim.lsp.util.convert_input_to_markdown_lines"] = false,
            ["vim.lsp.util.stylize_markdown"]                = false,
            ["cmp.entry.get_documentation"]                  = false,
          },
        },
        presets = {
          bottom_search        = false,  -- search prompt also floats (top)
          command_palette      = true,   -- group cmdline + popup at top
          long_message_to_split = true,  -- long :messages → split
          inc_rename           = false,
          lsp_doc_border       = false,
        },
      })
    end,
  }
end
