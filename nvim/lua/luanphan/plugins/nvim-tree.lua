return {
  {
    "nvim-tree/nvim-tree.lua",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      local tree_api = require("nvim-tree.api")
      local dependency_tree = require("luanphan.dependency_tree")
      vim.g.luanphan_show_dotfiles = 0
      vim.g.netrw_banner = 0
      vim.g.netrw_browse_split = 0
      vim.g.netrw_keepdir = 1
      vim.g.netrw_liststyle = 3

      local function on_attach(bufnr)
        tree_api.map.on_attach.default(bufnr)
        vim.keymap.set("n", "H", function()
          tree_api.filter.dotfiles.toggle()
          vim.g.luanphan_show_dotfiles = vim.g.luanphan_show_dotfiles == 1 and 0 or 1
        end, {
          buffer = bufnr,
          desc = "nvim-tree: Toggle Filter: Dotfiles",
          noremap = true,
          nowait = true,
          silent = true,
        })
      end

      require("nvim-tree").setup({
        on_attach = on_attach,
        disable_netrw = false,
        hijack_netrw = true,
        hijack_directories = {
          enable = true,
          auto_open = true,
        },
        filters = {
          custom = { "^\\.git$" },
          dotfiles = true,
        },
        view = {
          width = 40,
        },
        actions = {
          change_dir = {
            enable = false,
            restrict_above_cwd = true,
          },
          open_file = {
            window_picker = {
              exclude = {
                filetype = { "netrw", "notify", "packer", "qf", "diff", "fugitive", "fugitiveblame" },
                buftype = { "nofile", "terminal", "help" },
              },
            },
          },
        },
      })

      vim.keymap.set("n", "<leader>b", function()
        dependency_tree.toggle(tree_api)
      end, { desc = "Toggle file tree" })

      vim.keymap.set("n", "<leader>e", function()
        dependency_tree.focus(tree_api)
      end, { noremap = true, silent = true, desc = "Focus file tree" })
    end,
  },
}
