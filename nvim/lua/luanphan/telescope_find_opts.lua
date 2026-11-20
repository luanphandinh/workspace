local M = {}

function M.find_command(command, rules)
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
  vim.list_extend(result, require("luanphan.search_priority").ignore_args(rules))
  return result
end

function M.get_selection_window(picker)
  local editor = require("luanphan.editor_window")
  local source = picker.original_win_id
  if editor.is_editor(source) then return source end
  local target = editor.find(source)
  if target then return target end
  vim.cmd("botright new")
  return vim.api.nvim_get_current_win()
end

function M.find_files()
  local configured = require("telescope.config").pickers.find_files or {}
  local rules = require("luanphan.search_priority").read_rules()
  local opts = vim.deepcopy(configured)
  opts.hidden = vim.g.luanphan_show_dotfiles == 1
  opts.find_command = M.find_command(opts.find_command, rules)
  require("telescope.builtin").find_files(opts)
end

return M
