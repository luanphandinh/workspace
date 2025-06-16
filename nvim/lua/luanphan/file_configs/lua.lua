vim.api.nvim_create_autocmd("FileType", {
  pattern = "lua",
  callback = function()
    vim.bo.shiftwidth = 2   -- indent size
    vim.bo.tabstop = 2      -- tab width
    vim.bo.softtabstop = 2  -- how many spaces a <Tab> feels like
    vim.bo.expandtab = true -- use spaces instead of tabs
  end,
})
