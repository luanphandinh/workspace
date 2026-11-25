local M = {}
local backend, tmux

local function tmux_panel()
  if not tmux then
    tmux = require("luanphan.view_container.tmux.panel").create({
      settings = "floating_terminal",
      server = function()
        local socket = vim.g.luanphan_floating_tmux_socket
        if not socket and vim.env.TMUX then
          local inherited = vim.env.TMUX:match("^(.*),%d+,%d+$")
          if inherited and vim.uv.fs_stat(inherited) then socket = inherited end
        end
        return { socket = socket, config = vim.g.luanphan_floating_tmux_config }
      end,
      on_open = function() require("luanphan.agents.main").hide() end,
    })
  end
  return tmux
end

local function open_backend()
  local settings = require("luanphan.global_settings").read().floating_terminal
  if settings.backend == "shell" then return require("luanphan.terminal.floating_shell") end
  if vim.fn.executable("tmux") == 1 then return tmux_panel() end
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
