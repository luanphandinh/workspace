return function(use)
  use {
    "nvim-tree/nvim-tree.lua",
    requires = { "nvim-tree/nvim-web-devicons" },
    config = function()
      require("nvim-tree").setup({})

      vim.keymap.set("n", "<leader>b", function()
        require("nvim-tree.api").tree.toggle(false, true)
      end)

      vim.keymap.set("n", "<leader>e", function()
        -- If tree is already open and focused, switch back
        if vim.bo.filetype == "NvimTree" then
          vim.cmd("wincmd p") -- switch to previous window
        else
          require("nvim-tree.api").tree.find_file({ open = true, focus = true })
        end
      end, { noremap = true, silent = true })
    end,
  }
end
