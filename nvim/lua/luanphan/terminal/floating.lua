local M = {}
local backend

local function open_backend()
  local settings = require("luanphan.global_settings").read().floating_terminal
  if settings.backend == "shell" then return require("luanphan.terminal.floating_shell") end
  if vim.fn.executable("tmux") == 1 then return require("luanphan.terminal.tmux_panel") end
  vim.notify("tmux is unavailable. Set floating_terminal.backend to \"shell\" to use a local shell.", vim.log.levels.ERROR)
end

function M.hide()
  return backend and backend.hide() or false
end

function M.toggle()
  local editor_window = require("luanphan.view_container.editor").main_window()
  if M.hide() then
    if editor_window and vim.api.nvim_win_is_valid(editor_window) then vim.api.nvim_set_current_win(editor_window) end
    return
  end
  backend = open_backend()
  if backend then backend.toggle() end
end

return M
