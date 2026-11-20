local M = {}

function M.is_editor(win)
  if not win or not vim.api.nvim_win_is_valid(win) then return false end
  if vim.api.nvim_win_get_config(win).relative ~= "" or vim.wo[win].winfixbuf then return false end
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.bo[buf].buftype == "" and vim.bo[buf].filetype ~= "NvimTree"
end

function M.find(source)
  local previous = vim.fn.win_getid(vim.fn.winnr("#"))
  if previous ~= source and M.is_editor(previous) then return previous end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= source and M.is_editor(win) then return win end
  end
end

return M
