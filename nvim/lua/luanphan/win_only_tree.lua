-- |CTRL-W_o| / |:only| variant: close other windows in the tab but keep nvim-tree (and NERDTree) sidebars.

local M = {}

local TREE_FTS = { NvimTree = true, nerdtree = true }

local function is_tree_win(win)
  local buf = vim.api.nvim_win_get_buf(win)
  return TREE_FTS[vim.bo[buf].filetype] == true
end

function M.only_keep_tree()
  local tab = vim.api.nvim_get_current_tabpage()
  local cur = vim.api.nvim_get_current_win()
  local wins = vim.api.nvim_tabpage_list_wins(tab)
  local keep = { [cur] = true }
  for _, w in ipairs(wins) do
    if vim.api.nvim_win_is_valid(w) and is_tree_win(w) then
      keep[w] = true
    end
  end
  local to_close = {}
  for _, w in ipairs(wins) do
    if not keep[w] then
      to_close[#to_close + 1] = w
    end
  end
  for _, w in ipairs(to_close) do
    if vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
end

return M
