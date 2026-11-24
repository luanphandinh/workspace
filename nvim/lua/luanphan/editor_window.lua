local M = {}
local appearance_options = {
  "number", "relativenumber", "numberwidth", "signcolumn", "statuscolumn", "foldcolumn",
  "cursorline", "cursorlineopt", "cursorcolumn", "colorcolumn",
  "wrap", "linebreak", "breakindent", "breakindentopt", "showbreak", "list", "listchars",
  "scrolloff", "sidescrolloff", "winhighlight", "winblend", "winbar",
}

function M.appearance(win)
  local options = {}
  local scope = win and { win = win } or { scope = "global" }
  for _, name in ipairs(appearance_options) do
    options[name] = vim.api.nvim_get_option_value(name, scope)
  end
  return options
end

function M.apply_appearance(win, options)
  local scope = { win = win, scope = "local" }
  for _, name in ipairs(appearance_options) do
    local value = options[name]
    if value ~= nil and vim.api.nvim_get_option_value(name, { win = win }) ~= value then
      vim.api.nvim_set_option_value(name, value, scope)
    end
  end
end

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
