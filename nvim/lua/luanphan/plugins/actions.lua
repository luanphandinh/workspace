return {
  {
    "luanphan-actions",
    virtual = true,
    keys = {
      {
        "<leader>tg",
        function()
          require("luanphan.actions").toggle_gitignore()
        end,
        desc = "Toggle Gitignore",
      },
      {
        "<leader>rr",
        function()
          require("luanphan.run_actions").pick()
        end,
        desc = "Run action",
      },
      {
        "<leader>rc",
        function()
          require("luanphan.run_actions").open_editor()
        end,
        desc = "Configure actions",
      },
    },
  },
}
