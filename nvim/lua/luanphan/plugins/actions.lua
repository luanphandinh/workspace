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
    },
  },
}
