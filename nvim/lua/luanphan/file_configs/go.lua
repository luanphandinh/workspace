local M = {}

local function apply(buf)
  vim.bo[buf].shiftwidth = 4
  vim.bo[buf].tabstop = 4
  vim.bo[buf].softtabstop = 4
  vim.bo[buf].expandtab = false
end

function M.setup()
  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("LuanphanGoFileConfig", { clear = true }),
    pattern = "go",
    callback = function(ev)
      apply(ev.buf)
    end,
  })

  if vim.bo.filetype == "go" then
    apply(0)
  end
end

return M
