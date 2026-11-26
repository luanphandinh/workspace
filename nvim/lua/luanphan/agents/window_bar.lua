local M = {}
local agents = require("luanphan.agents.main")
local tmux = require("luanphan.agents.tmux")
local sessions = require("luanphan.agents.sessions")
local pane_order = require("luanphan.view_container.pane_order")
local status = require("luanphan.agents.status")
local views = require("luanphan.view_container")
local editor = require("luanphan.view_container.editor")

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
  local by_workspace = {}
  for _, thread in ipairs(threads) do
    local workspace = thread.workspace
    by_workspace[workspace] = by_workspace[workspace] or {}
    table.insert(by_workspace[workspace], thread)
  end
  local workspaces = vim.tbl_keys(by_workspace)
  table.sort(workspaces)
  local result = {}
  for _, workspace in ipairs(workspaces) do
    local group = { id = workspace, title = vim.fn.fnamemodify(workspace, ":t"), items = {} }
    local entries = by_workspace[workspace]
    table.sort(entries, function(a, b)
      if a.bufnr or b.bufnr then return (a.bufnr or math.huge) < (b.bufnr or math.huge) end
      if a.last_used ~= b.last_used then return a.last_used > b.last_used end
      return a.thread_id < b.thread_id
    end)
    local recent = entries[1]
    for _, thread in ipairs(entries) do
      if thread.bufnr and thread.last_used > recent.last_used then recent = thread end
    end
    pane_order.sort(entries)
    for _, thread in ipairs(entries) do
      local item = {
        id = sessions.key(thread), bufnr = thread.bufnr, label = thread.agent_label,
        icon = agents.agent_icon(thread.agent), thread = thread,
      }
      group.items[#group.items + 1] = item
      if thread == recent then group.active = item end
    end
    result[#result + 1] = group
  end
  return result
end

function M.select_session(session, opts)
  if not session then return false end
  local activate = require("luanphan.plugins.worktree").activate_agent
  return agents.container:with_panel_windows(function(windows) return activate(session, windows, opts) end)
end

bar = require("luanphan.view_container.window_bar").create({
  title = "Workspaces",
  filetype = "agent-window-bar",
  groups = groups,
  load_order = tmux.load_window_order,
  save_order = tmux.save_window_order,
  activate = function(item, view_mode)
    return M.select_session(item.thread, view_mode and { view_mode = true } or nil)
  end,
  reorder = function(_, items)
    agents.container:save_pane_order(vim.tbl_map(function(item) return item.thread end, items))
    agents.container:refresh()
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
      sessions.forget(session.agent, session.thread_id)
      bar:refresh(true)
    end
  end,
  bind = function(buf)
    editor.bind(buf)
    agents.map_create_shortcuts(buf)
    vim.keymap.set("n", "<leader>a", agents.toggle, { buffer = buf })
  end,
})

M.bar = bar
function M.refresh(keep_cursor)
  bar:refresh(keep_cursor)
end

return M
