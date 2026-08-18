return {
  {
    "nvim-tree/nvim-tree.lua",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      local tree_api = require("nvim-tree.api")
      vim.g.luanphan_show_dotfiles = 0

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
        },
      })

      vim.keymap.set("n", "<leader>b", function()
        tree_api.tree.toggle(false, true)
      end, { desc = "Toggle NvimTree" })

      vim.keymap.set("n", "<leader>e", function()
        -- If tree is already open and focused, switch back
        if vim.bo.filetype == "NvimTree" then
          vim.cmd("wincmd p") -- switch to previous window
        else
          tree_api.tree.find_file({ open = true, focus = true })
        end
      end, { noremap = true, silent = true, desc = "Focus NvimTree" })
    end,
  },
}
