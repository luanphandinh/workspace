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
    },
  },
}
