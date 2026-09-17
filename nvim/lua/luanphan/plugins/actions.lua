return {
  {
    "luanphan-command-palette",
    virtual = true,
    keys = {
      {
        "<leader>cp",
        function()
          require("lazy").load({ plugins = { "telescope.nvim" } })
          require("luanphan.actions").show_command_palette()
        end,
        desc = "Show commands",
      },
      {
        "<leader>tg",
        function()
          require("luanphan.actions").toggle_gitignore()
        end,
        desc = "Toggle Gitignore",
      },
    },
  },
}
