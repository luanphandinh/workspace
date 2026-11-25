return {
  {
    "MeanderingProgrammer/render-markdown.nvim",
    ft = "markdown",
    keys = {
      { "<leader>-p", "<cmd>RenderMarkdown buf_toggle<cr>", ft = "markdown", desc = "Toggle preview" },
    },
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = {
      anti_conceal = { enabled = false },
      indent = {
        enabled = true,
        per_level = 2,
        skip_level = 0,
        skip_heading = true,
        icon = "",
      },
      pipe_table = { grid = true },
    },
    config = function(_, opts)
      local renderer = require("render-markdown.render.markdown.table")
      local border_row = renderer.border_row
      renderer.border_row = function(self, row, position, lines)
        if position ~= "body" or not self.context.config.indent.enabled then
          return border_row(self, row, position, lines)
        end
        -- Body dividers already have the section indent in their row prefix.
        local body = setmetatable({
          indent = function()
            return { line = function() return self:line() end }
          end,
        }, { __index = self })
        return border_row(body, row, position, lines)
      end

      local marks = require("render-markdown.lib.marks")
      local replace = marks.replace
      marks.replace = function(self, config, node, lines)
        if config ~= self.context.config.pipe_table then
          return replace(self, config, node, lines)
        end
        -- Keep one screen line per table row so the cursor can follow long tables.
        local _, source = node:line("first", 0)
        self:add(config, "table_border", node.start_row, 0, {
          end_row = node.start_row,
          end_col = #source,
          conceal = "",
          virt_text = lines[1],
          virt_text_pos = "overlay",
          virt_text_win_col = 0,
          virt_lines = vim.list_slice(lines, 2),
        })
      end
      require("render-markdown").setup(opts)
    end,
  },
  {
    "iamcco/markdown-preview.nvim",
    cmd = { "MarkdownPreviewToggle", "MarkdownPreview", "MarkdownPreviewStop" },
    ft = { "markdown", "rmd" },
    build = "cd app && npx --yes yarn install",
    init = function()
      local preview_port = tonumber(vim.env.NEOVIDE_MARKDOWN_PREVIEW_PORT)
      local remote_tunnel = require("luanphan.remote_tunnel").enabled()

      vim.g.mkdp_auto_close = 0
      vim.g.mkdp_theme = "light"
      vim.g.mkdp_filetypes = { "markdown", "rmd" }
      if preview_port and remote_tunnel then
        vim.g.mkdp_port = tostring(preview_port)
        vim.g.mkdp_echo_preview_url = 1
        vim.g.mkdp_browserfunc = "WorkspaceRemoteTunnelOpen"
      end
      vim.g.mkdp_preview_options = {
        disable_sync_scroll = 1,
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
