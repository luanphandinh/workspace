return {
  {
    "luanphan-qf-replace",
    virtual = true,
    cmd = { "QfReplace", "QfReplaceLine" },
    keys = {
      {
        "<leader>sr",
        function()
          require("luanphan.qf_replace").prompt_cfdo_substitute()
        end,
        desc = "Quickfix: replace in all listed files (use g/ then <C-q> first)",
      },
    },
    config = function()
      require("luanphan.qf_replace").setup()
    end,
  },
}
