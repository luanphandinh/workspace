-- Auto-format JSON files on save
vim.api.nvim_create_autocmd("FileType", {
  pattern = "json",
  callback = function()
    -- Format on save using vim's built-in JSON formatting
    vim.api.nvim_create_autocmd("BufWritePre", {
      buffer = 0,
      callback = function()
        -- Save cursor position
        local cursor = vim.api.nvim_win_get_cursor(0)
        -- Format the buffer
        vim.cmd("%!jq .")
        -- Restore cursor position
        pcall(vim.api.nvim_win_set_cursor, 0, cursor)
      end,
    })
  end,
})

-- Manual format keymap for JSON
vim.api.nvim_create_autocmd("FileType", {
  pattern = "json",
  callback = function()
    vim.keymap.set("n", "<leader>fj", function()
      local cursor = vim.api.nvim_win_get_cursor(0)
      vim.cmd("%!jq .")
      pcall(vim.api.nvim_win_set_cursor, 0, cursor)
    end, { buffer = true, desc = "Format JSON" })
  end,
})
