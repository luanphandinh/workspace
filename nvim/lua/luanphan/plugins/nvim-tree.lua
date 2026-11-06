return {
  {
    "nvim-tree/nvim-tree.lua",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      local tree_api = require("nvim-tree.api")
      local dependency_tree = require("luanphan.dependency_tree")
      local tree_width = 40
      vim.g.luanphan_show_dotfiles = 0
      vim.g.netrw_banner = 0
      vim.g.netrw_liststyle = 3

      local function on_attach(bufnr)
        tree_api.map.on_attach.default(bufnr)
        vim.keymap.set("n", "H", function()
          tree_api.filter.dotfiles.toggle()
          vim.g.luanphan_show_dotfiles = vim.g.luanphan_show_dotfiles == 1 and 0 or 1
        end, {
          buffer = bufnr,
          desc = "nvim-tree: Toggle Filter: Dotfiles",
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
          width = tree_width,
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
              },
            },
          },
        },
      })

      local function restore_tree_width()
        local tree_win = tree_api.tree.winid()
        if not tree_win or not vim.api.nvim_win_is_valid(tree_win) then
          return
        end
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(tree_win))) do
          if win ~= tree_win and vim.api.nvim_win_get_config(win).relative == "" then
            vim.wo[tree_win].winfixwidth = true
            if vim.api.nvim_win_get_width(tree_win) ~= tree_width then
              pcall(vim.api.nvim_win_set_width, tree_win, tree_width)
            end
            return
          end
        end
      end

      vim.api.nvim_create_autocmd({ "WinNew", "WinResized", "VimResized" }, {
        group = vim.api.nvim_create_augroup("LuanphanNvimTreeWidth", { clear = true }),
        callback = function()
          vim.schedule(restore_tree_width)
        end,
      })
      vim.schedule(restore_tree_width)

      vim.keymap.set("n", "<leader>b", function()
        dependency_tree.toggle(tree_api)
      end, { desc = "Toggle file tree" })

      vim.keymap.set("n", "<leader>e", function()
        dependency_tree.focus(tree_api)
      end, { silent = true, desc = "Focus file tree" })
    end,
  },
}
