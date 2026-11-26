-- Agents sidebar: the panel supplies the rows; selecting one goes through the workspace switcher.
local M = {}
local agents = require("luanphan.agents.main")

function M.select_session(session, opts)
  if not session then return false end
  local activate = require("luanphan.plugins.worktree").activate_agent
  return agents.container:with_panel_windows(function(windows) return activate(session, windows, opts) end)
end

M.bar = agents.panel.create_bar({
  title = "Workspaces",
  filetype = "agent-window-bar",
  activate = function(item, view_mode)
    return M.select_session(item.thread, view_mode and { view_mode = true } or nil)
  end,
})

return M
