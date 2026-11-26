local M = {}
local agents = require("luanphan.agents.main")
local sessions = require("luanphan.agents.sessions")
local status = require("luanphan.agents.status")
local views = require("luanphan.view_container")

local bar

local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local status_icons = {
  idle = { "·", "Comment" },
  done = { "✓", "DiagnosticOk" },
  blocked = { "!", "DiagnosticWarn" },
  error = { "!", "DiagnosticError" },
}

local function groups()
  local threads = require("luanphan.plugins.worktree").list_agent_sessions(true)
  return views.workspace_groups(threads, function(thread)
    return {
      id = sessions.key(thread), sort_id = thread.thread_id, bufnr = thread.bufnr, label = thread.label,
      icon = agents.agent_icon(thread.kind), thread = thread, pane_order = thread.pane_order,
    }
  end)
end

function M.select_session(session, opts)
  if not session then return false end
  local activate = require("luanphan.plugins.worktree").activate_agent
  return agents.container:with_panel_windows(function(windows) return activate(session, windows, opts) end)
end

bar = agents.container:create_bar({
  title = "Workspaces",
  filetype = "agent-window-bar",
  groups = groups,
  activate = function(item, view_mode)
    return M.select_session(item.thread, view_mode and { view_mode = true } or nil)
  end,
  reorder = function(_, items)
    agents.container:reorder_panes(vim.tbl_map(function(item) return item.thread end, items))
  end,
  status = function(item, frame)
    local current = status.current(item.bufnr)
    if current == "working" then return spinner[(frame - 1) % #spinner + 1], "DiagnosticInfo" end
    local icon = status_icons[current]
    if icon then return unpack(icon) end
  end,
  dismiss = function(item)
    local session = item and item.thread
    if session and session.thread_id and not session.bufnr then
      sessions.forget(session.kind, session.thread_id)
      bar:refresh(true)
    end
  end,
})

M.bar = bar
function M.refresh(keep_cursor)
  bar:refresh(keep_cursor)
end

return M
