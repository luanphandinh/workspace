local M = {}
local api = vim.api
local agents = require("luanphan.agents.main")
local tmux = require("luanphan.agents.tmux")
local editor_tile = require("luanphan.view_container.editor")
local sessions = require("luanphan.agents.sessions")
local status = require("luanphan.agents.status")
local close_window = require("luanphan.agents.terminal-chat").close_window
local views = require("luanphan.view_container")

local main, focused_terminal
local switching_workspace = false
local bar

local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local status_icons = {
  idle = { "·", "Comment" },
  done = { "✓", "DiagnosticOk" },
  blocked = { "!", "DiagnosticWarn" },
  error = { "!", "DiagnosticError" },
}

local function valid(win)
  return win and api.nvim_win_is_valid(win)
end

local function groups()
  local threads = require("luanphan.plugins.worktree").list_agent_sessions(true)
  local by_workspace, paths, counts = {}, {}, {}
  for _, thread in ipairs(threads) do
    local workspace = thread.workspace
    by_workspace[workspace] = by_workspace[workspace] or {}
    table.insert(by_workspace[workspace], thread)
    if thread.bufnr and agents.uses_status_file(thread.agent) then
      local path = status.path(thread.agent, thread.path)
      paths[thread.bufnr], counts[path] = path, (counts[path] or 0) + 1
    end
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
    sessions.sort_by_order(entries)
    for _, thread in ipairs(entries) do
      local path = paths[thread.bufnr]
      local item = {
        id = sessions.key(thread), bufnr = thread.bufnr, label = thread.agent_label,
        icon = agents.agent_icon(thread.agent), thread = thread,
        status_path = counts[path] == 1 and path or nil,
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
  if not valid(main) then return activate(session, nil, opts) end
  vim.cmd.stopinsert()
  switching_workspace = true
  local ok, result = pcall(activate, session, views.group_windows(main), opts)
  switching_workspace = false
  if not ok then error(result) end
  return result
end

bar = require("luanphan.view_container.window_bar").create({
  title = "Workspaces",
  filetype = "agent-window-bar",
  history = agents.history,
  groups = groups,
  load_order = tmux.load_window_order,
  save_order = tmux.save_window_order,
  active_window = function()
    if valid(focused_terminal) and views.group_anchor(focused_terminal) == main then return focused_terminal end
    return main
  end,
  activate = function(item, view_mode)
    return M.select_session(item.thread, view_mode and { view_mode = true } or nil)
  end,
  reorder = function(_, items)
    sessions.set_order(vim.tbl_map(function(item) return item.thread end, items))
    agents.refresh_tabs(main)
  end,
  status = function(item, frame)
    local current = status.current(item.bufnr, item.status_path)
    if current == "working" or current == "running" then return spinner[(frame - 1) % #spinner + 1], "DiagnosticInfo" end
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
    agents.map_create_shortcuts(buf)
    vim.keymap.set("n", "<leader>a", function() if valid(main) then close_window(main) end end, { buffer = buf })
  end,
})

function M.layout(win, layout)
  if valid(main) and main ~= win then close_window(main) end
  main = win
  local old = bar.win
  bar:layout(win, layout)
  if bar.win ~= old then bar:refresh() end
end

function M.refresh(keep_cursor)
  bar:refresh(keep_cursor)
end

function M.update_title(buf)
  bar:update_title(buf, views.tab_label(buf))
end

function M.navigate(win, direction)
  local moved = views.focus_neighbor(win, direction, function(neighbor)
    local buf = api.nvim_win_get_buf(neighbor)
    agents.focus(vim.b[buf].luanphan_agent_name, buf, { view_mode = true })
  end)
  if not moved then bar:focus_towards(direction) end
end

function M.attach(buf)
  bar:attach(buf)
  bar:map_jumps(buf, false)
  vim.keymap.set("t", "<C-h>", "<C-h>", { buffer = buf, silent = true, nowait = true })
end

local group = api.nvim_create_augroup("LuanphanAgentWindowBar", { clear = true })
api.nvim_create_autocmd("WinClosed", {
  group = group,
  callback = function(args)
    local win = tonumber(args.match)
    if win ~= main and win ~= bar.win then return end
    local anchor = main
    main, focused_terminal = nil, nil
    bar.win, bar.anchor = nil, nil
    bar:stop_timer()
    if anchor then views.close_group(anchor, win) end
  end,
})

api.nvim_create_autocmd("WinEnter", {
  group = group,
  callback = function()
    local current = api.nvim_get_current_win()
    if main and current ~= bar.win and views.group_anchor(current) == main then
      if current ~= editor_tile.window(main) then focused_terminal = current end
      return
    end
    if switching_workspace or not valid(main) or api.nvim_win_get_config(current).relative ~= "" then return end
    local win = main
    vim.schedule(function()
      if win == main and not switching_workspace and valid(win) and api.nvim_win_get_config(0).relative == "" then
        close_window(win)
      end
    end)
  end,
})

return M
