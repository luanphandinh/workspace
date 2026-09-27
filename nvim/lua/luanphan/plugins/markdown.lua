return {
  {
    "iamcco/markdown-preview.nvim",
    cmd = { "MarkdownPreviewToggle", "MarkdownPreview", "MarkdownPreviewStop" },
    ft = { "markdown", "rmd" },
    build = "cd app && npx --yes yarn install",
    init = function()
      local preview_port = tonumber(vim.env.NEOVIDE_MARKDOWN_PREVIEW_PORT)
      local remote_open_port = tonumber(vim.env.NEOVIDE_REMOTE_OPEN_PORT)

      vim.g.mkdp_auto_start = 0
      vim.g.mkdp_auto_close = 0
      vim.g.mkdp_refresh_slow = 0
      vim.g.mkdp_command_for_global = 0
      vim.g.mkdp_open_to_the_world = 0
      vim.g.mkdp_theme = "light"
      vim.g.mkdp_filetypes = { "markdown", "rmd" }
      if preview_port and remote_open_port then
        vim.g.mkdp_port = tostring(preview_port)
        vim.g.mkdp_echo_preview_url = 1
        vim.g.mkdp_browserfunc = "WorkspaceMarkdownPreviewOpen"

        _G.workspace_markdown_preview_open = function(url)
          if type(url) ~= "string" or not url:match("^https?://") then
            vim.notify("Markdown preview returned an invalid URL", vim.log.levels.ERROR)
            return
          end

          local client = vim.uv.new_tcp()
          client:connect("127.0.0.1", remote_open_port, function(connect_error)
            if connect_error then
              client:close()
              vim.schedule(function()
                vim.notify("Markdown preview could not reach the local browser bridge", vim.log.levels.ERROR)
              end)
              return
            end

            client:write(url .. "\n", function(write_error)
              client:close()
              if write_error then
                vim.schedule(function()
                  vim.notify("Markdown preview could not send the URL to the local browser", vim.log.levels.ERROR)
                end)
              end
            end)
          end)
        end

        vim.cmd([[
          function! WorkspaceMarkdownPreviewOpen(url) abort
            call v:lua.workspace_markdown_preview_open(a:url)
          endfunction
        ]])
      end
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
