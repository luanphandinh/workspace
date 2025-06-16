vim.api.nvim_create_autocmd("FileType", {
  pattern = "go",
  callback = function()
    vim.bo.shiftwidth = 4    -- indent size
    vim.bo.tabstop = 4       -- tab width
    vim.bo.softtabstop = 4   -- how many spaces a <Tab> feels like
    vim.bo.expandtab = false -- use spaces instead of tabs
  end,
})
