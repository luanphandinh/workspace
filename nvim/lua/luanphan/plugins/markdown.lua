return {
  {
    "iamcco/markdown-preview.nvim",
    cmd = { "MarkdownPreviewToggle", "MarkdownPreview", "MarkdownPreviewStop" },
    ft = { "markdown", "rmd" },
    build = "cd app && npx --yes yarn install",
    init = function()
      local preview_port = tonumber(vim.env.NEOVIDE_MARKDOWN_PREVIEW_PORT)
      local remote_tunnel = require("luanphan.remote_tunnel").enabled()

      vim.g.mkdp_auto_start = 0
      vim.g.mkdp_auto_close = 0
      vim.g.mkdp_refresh_slow = 0
      vim.g.mkdp_open_to_the_world = 0
      vim.g.mkdp_theme = "light"
      vim.g.mkdp_filetypes = { "markdown", "rmd" }
      if preview_port and remote_tunnel then
        vim.g.mkdp_port = tostring(preview_port)
        vim.g.mkdp_echo_preview_url = 1
        vim.g.mkdp_browserfunc = "WorkspaceRemoteTunnelOpen"
      end
      vim.g.mkdp_preview_options = {
        disable_sync_scroll = 1,
        sync_scroll_type = "middle",
        hide_yaml_meta = 1,
        content_editable = false,
        disable_filename = 0,
        toc = { containerClass = "preview-toc", level = { 1, 2, 3, 4, 5, 6 } },
      }
    end,
    config = function()
      local base_css = vim.api.nvim_get_runtime_file("app/_static/markdown.css", false)[1]
      local sidebar_css = vim.fn.stdpath("config") .. "/markdown-preview/sidebar.css"
      local styles = vim.fn.readfile(base_css)
      vim.list_extend(styles, vim.fn.readfile(sidebar_css))
      local preview_css = vim.fn.stdpath("cache") .. "/markdown-preview.css"
      vim.fn.mkdir(vim.fn.stdpath("cache"), "p")
      vim.fn.writefile(styles, preview_css)
      vim.g.mkdp_markdown_css = preview_css

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
