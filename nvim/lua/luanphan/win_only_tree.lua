-- |CTRL-W_o| / |:only| variant: close other windows in the tab but keep nvim-tree (and NERDTree) sidebars.

local M = {}

local TREE_FTS = { NvimTree = true, nerdtree = true }

local function is_tree_win(win)
  local buf = vim.api.nvim_win_get_buf(win)
  return TREE_FTS[vim.bo[buf].filetype] == true
end

function M.only_keep_tree()
  local tab = vim.api.nvim_get_current_tabpage()
  local current = vim.api.nvim_get_current_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if win ~= current and vim.api.nvim_win_is_valid(win) and not is_tree_win(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

return M
