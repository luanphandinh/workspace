local M = {}

local function apply(buf)
  vim.bo[buf].shiftwidth = 2
  vim.bo[buf].tabstop = 2
  vim.bo[buf].softtabstop = 2
  vim.bo[buf].expandtab = true
end

function M.setup()
  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("LuanphanLuaFileConfig", { clear = true }),
    pattern = "lua",
    callback = function(ev)
      apply(ev.buf)
    end,
  })

  if vim.bo.filetype == "lua" then
    apply(0)
  end
end

return M
