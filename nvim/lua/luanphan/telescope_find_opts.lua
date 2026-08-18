local M = {}

function M.find_command(command)
  local source = type(command) == "table" and command or { "rg", "--files", "--follow" }
  local result = {}
  for _, arg in ipairs(source) do
    if arg ~= "--hidden" then
      result[#result + 1] = arg
    end
  end
  if vim.g.luanphan_show_dotfiles == 1 then
    result[#result + 1] = "--hidden"
  end
  return result
end

function M.find_files()
  local configured = require("telescope.config").pickers.find_files or {}
  local opts = vim.deepcopy(configured)
  opts.hidden = vim.g.luanphan_show_dotfiles == 1
  opts.find_command = M.find_command(opts.find_command)
  require("telescope.builtin").find_files(opts)
end

return M
