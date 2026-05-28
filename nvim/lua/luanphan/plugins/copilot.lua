return {
  -- github/copilot.vim: optional; not loaded until <leader>tc (see luanphan.copilot_toggle).
  -- First auth: after first load, run :Copilot setup if needed.
  {
    "github/copilot.vim",
    branch = "release",
    lazy = true,
    init = function()
      vim.g.copilot_filetypes = {
        ["*"] = false,
        go = true,
      }
    end,
  },
}
