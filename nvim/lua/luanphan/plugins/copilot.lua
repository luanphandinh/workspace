return function(use)
  -- github/copilot.vim: optional; not loaded until <leader>tc (see luanphan.copilot_toggle).
  -- First auth: after first load, run :Copilot setup if needed.
  use {
    "github/copilot.vim",
    branch = "release",
    opt = true, -- Lazy Load
    config = function()
      vim.g.copilot_enabled = true -- After load, turned on by default
    end,
  }
end
