return {
  {
    "iamcco/markdown-preview.nvim",
    cmd = { "MarkdownPreviewToggle", "MarkdownPreview", "MarkdownPreviewStop" },
    ft = { "markdown", "rmd" },
    build = "cd app && npx --yes yarn install",
    init = function()
      vim.g.mkdp_auto_start = 0
      vim.g.mkdp_auto_close = 1
      vim.g.mkdp_refresh_slow = 0
      vim.g.mkdp_command_for_global = 0
      vim.g.mkdp_open_to_the_world = 0
      vim.g.mkdp_theme = "light"
      vim.g.mkdp_filetypes = { "markdown", "rmd" }
      vim.g.mkdp_preview_options = {
        disable_sync_scroll = 1,
        sync_scroll_type = "middle",
        hide_yaml_meta = 1,
        content_editable = false,
        disable_filename = 0,
      }
    end,
    config = function()
      local group = vim.api.nvim_create_augroup("LuanphanMarkdownPreviewRefresh", { clear = true })
      vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP", "BufWritePost" }, {
        group = group,
        pattern = { "*.md", "*.markdown", "*.rmd" },
        callback = function(args)
          if vim.b[args.buf].MarkdownPreviewToggleBool ~= 1 then
            return
          end
          pcall(vim.fn["mkdp#rpc#preview_refresh"])
        end,
      })
    end,
  },
}
