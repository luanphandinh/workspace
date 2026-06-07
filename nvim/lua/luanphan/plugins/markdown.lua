return {
  {
    "iamcco/markdown-preview.nvim",
    cmd = { "MarkdownPreviewToggle", "MarkdownPreview", "MarkdownPreviewStop" },
    ft = { "markdown", "rmd" },
    build = "cd app && npx --yes yarn install",
    init = function()
      vim.g.mkdp_auto_start = 0
      vim.g.mkdp_auto_close = 1
      vim.g.mkdp_refresh_slow = 1
      vim.g.mkdp_command_for_global = 0
      vim.g.mkdp_open_to_the_world = 0
      vim.g.mkdp_filetypes = { "markdown", "rmd" }
      vim.g.mkdp_preview_options = {
        disable_sync_scroll = 1,
        sync_scroll_type = "middle",
        hide_yaml_meta = 1,
        content_editable = false,
        disable_filename = 0,
      }
    end,
  },
}
