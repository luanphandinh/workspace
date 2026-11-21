local M = {}
local agents = require("luanphan.agents.main")
local agent_sessions = require("luanphan.agents.sessions")
local jumplist = require("luanphan.agents.jumplist")
local agent_status = require("luanphan.agents.status")
local close_window = require("luanphan.agents.terminal-chat").close_window
local view_container = require("luanphan.view_container")

local main, sidebar, focused_terminal
local rows = {}
local thread_lines = {}
local folded = {}
local workspace_order
local return_to_input = false
local switching_workspace = false
local ns = vim.api.nvim_create_namespace("LuanphanAgentSidebar")
local status_ns = vim.api.nvim_create_namespace("LuanphanAgentSidebarStatus")
local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_frame = 1
local status_timer
local status_icons = {
  idle = { "·", "Comment" },
  done = { "✓", "DiagnosticOk" },
  blocked = { "!", "DiagnosticWarn" },
  error = { "!", "DiagnosticError" },
}

local function valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function active_terminal()
  if valid(focused_terminal) and vim.w[focused_terminal].luanphan_view_anchor == main then
    return focused_terminal
  end
  return main
end

local function stop_status_timer()
  if status_timer then vim.fn.timer_stop(status_timer) end
  status_timer = nil
end

local function render_statuses()
  if not valid(sidebar) or not valid(main) or vim.w[main].luanphan_agent_sidebar ~= sidebar
    or vim.api.nvim_win_get_config(sidebar).hide then
    stop_status_timer()
    return
  end
  local buf = vim.api.nvim_win_get_buf(sidebar)
  for bufnr, thread in pairs(thread_lines) do
    if thread.status_col and vim.api.nvim_buf_is_valid(bufnr) then
      local status = agent_status.current(bufnr, thread.status_path)
      local icon = status_icons[status]
      if status == "working" or status == "running" then
        icon = { spinner[spinner_frame], "DiagnosticInfo" }
      end
      local glyph, highlight
      if icon then glyph, highlight = unpack(icon) end
      if glyph ~= thread.glyph or highlight ~= thread.highlight then
        if glyph then
          vim.api.nvim_buf_set_extmark(buf, status_ns, thread.row - 1, 0, {
            id = bufnr,
            virt_text = { { glyph, highlight } },
            virt_text_win_col = thread.status_col,
            hl_mode = "combine",
          })
        else
          vim.api.nvim_buf_del_extmark(buf, status_ns, bufnr)
        end
        thread.glyph, thread.highlight = glyph, highlight
      end
    end
  end
end

local function refresh_statuses()
  render_statuses()
  if status_timer or not valid(sidebar) or vim.api.nvim_win_get_config(sidebar).hide then return end
  status_timer = vim.fn.timer_start(130, function()
    spinner_frame = spinner_frame % #spinner + 1
    render_statuses()
  end, { ["repeat"] = -1 })
end

local function fit(text, width)
  if width < 1 then return "" end
  if vim.fn.strdisplaywidth(text) <= width then return text end
  local limit = width - vim.fn.strdisplaywidth("…")
  if limit < 0 then return "" end
  local characters = limit
  local prefix = vim.fn.strcharpart(text, 0, characters, true)
  while vim.fn.strdisplaywidth(prefix) > limit do
    characters = characters - 1
    prefix = vim.fn.strcharpart(text, 0, characters, true)
  end
  return prefix .. "…"
end

local function ordered(items, order)
  if not order then return items end
  local remaining, result = {}, {}
  for _, item in ipairs(items) do remaining[item] = true end
  for _, id in ipairs(order) do
    if remaining[id] then
      result[#result + 1] = id
      remaining[id] = nil
    end
  end
  for _, item in ipairs(items) do
    if remaining[item] then result[#result + 1] = item end
  end
  return result
end

function M.refresh(keep_cursor)
  if not valid(sidebar) or not valid(main) then return end
  local sessions = require("luanphan.plugins.worktree").list_agent_sessions(true)
  local groups = {}
  local live = {}
  local status_paths, status_counts = {}, {}
  for _, session in ipairs(sessions) do
    groups[session.workspace] = groups[session.workspace] or {}
    table.insert(groups[session.workspace], session)
    if session.bufnr then
      live[session.bufnr] = true
      local path = agent_status.path(session.agent, session.path)
      status_paths[session.bufnr] = path
      status_counts[path] = (status_counts[path] or 0) + 1
    end
  end
  local offsets = jumplist.offsets(live)
  local number_width = 2
  for _, offset in pairs(offsets) do
    number_width = math.max(number_width, #tostring(offset))
  end
  local number_format = " %" .. number_width .. "s "

  local workspaces = vim.tbl_keys(groups)
  table.sort(workspaces)
  workspaces = ordered(workspaces, workspace_order)
  local active = vim.api.nvim_win_get_buf(active_terminal())
  local width = vim.api.nvim_win_get_width(sidebar) - 1
  local lines, headings, provider_marks = {}, {}, {}
  local active_row
  rows = {}
  thread_lines = {}
  for workspace_index, workspace in ipairs(workspaces) do
    local threads = groups[workspace]
    table.sort(threads, function(a, b)
      if a.bufnr or b.bufnr then return (a.bufnr or math.huge) < (b.bufnr or math.huge) end
      if a.last_used ~= b.last_used then return a.last_used > b.last_used end
      return a.thread_id < b.thread_id
    end)
    local is_folded = folded[workspace]
    local prefix = is_folded and "▸ " or " "
    lines[#lines + 1] = prefix .. fit(vim.fn.fnamemodify(workspace, ":t"), width - vim.fn.strdisplaywidth(prefix))
    local heading = #lines
    headings[#headings + 1] = heading
    local recent = threads[1]
    for _, thread in ipairs(threads) do
      if thread.bufnr and thread.last_used > recent.last_used then recent = thread end
      if is_folded and thread.bufnr == active then active_row = heading end
    end
    rows[heading] = { workspace = workspace, session = recent, items = workspaces, index = workspace_index }
    agent_sessions.sort_by_order(threads)
    for thread_index, thread in ipairs(is_folded and {} or threads) do
      local prefix = string.format(number_format, offsets[thread.bufnr] or "")
      local icon = agents.agent_icon(thread.agent)
      local icon_col = width - vim.fn.strdisplaywidth(icon)
      local status_col = icon_col - 2
      local title_width = status_col - #prefix - 1
      local status_path = status_paths[thread.bufnr]
      lines[#lines + 1] = prefix .. fit(thread.agent_label, title_width)
      rows[#lines] = {
        workspace = workspace, session = thread, items = threads, index = thread_index, key = agent_sessions.key(thread),
      }
      if icon_col >= #prefix then
        provider_marks[#lines] = {
          virt_text = { { icon, "Comment" } },
          virt_text_win_col = icon_col,
          hl_mode = "combine",
        }
      end
      if thread.bufnr then
        thread_lines[thread.bufnr] = {
          row = #lines,
          title_col = #prefix,
          title_width = title_width,
          status_col = title_width >= 0 and status_col or nil,
          status_path = status_counts[status_path] == 1 and status_path or nil,
        }
        if thread.bufnr == active then active_row = #lines end
      end
    end
  end

  local buf = vim.api.nvim_win_get_buf(sidebar)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, status_ns, 0, -1)
  for _, heading in ipairs(headings) do
    vim.api.nvim_buf_set_extmark(buf, ns, heading - 1, 0, { line_hl_group = "Directory" })
  end
  for row, mark in pairs(provider_marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, mark)
  end
  for _, thread in pairs(thread_lines) do
    vim.api.nvim_buf_set_extmark(buf, ns, thread.row - 1, 0, {
      end_col = thread.title_col,
      hl_group = "Comment",
    })
  end
  if active_row then
    vim.api.nvim_buf_set_extmark(buf, ns, active_row - 1, 0, { line_hl_group = "Title" })
    if not keep_cursor then vim.api.nvim_win_set_cursor(sidebar, { active_row, 0 }) end
  end
  refresh_statuses()
end

local function selected_row()
  return rows[vim.api.nvim_win_get_cursor(sidebar)[1]]
end

local function refresh_at(workspace, key)
  M.refresh(true)
  for line, row in ipairs(rows) do
    if row.workspace == workspace and row.key == key then
      vim.api.nvim_win_set_cursor(sidebar, { line, 0 })
      return
    end
  end
end

local function set_folded(value)
  local row = selected_row()
  if not row or folded[row.workspace] == value then return end
  folded[row.workspace] = value
  refresh_at(row.workspace)
end

local function move_row(delta)
  local row = selected_row()
  if not row then return end
  local items, index = row.items, row.index
  local target = index + delta
  if not items[target] then return end
  items[index], items[target] = items[target], items[index]
  if row.key then
    agent_sessions.set_order(items)
    agents.refresh_tabs(main)
  else
    workspace_order = items
  end
  refresh_at(row.workspace, row.key)
end

function M.select_session(session, opts)
  if not session then return false end
  local activate = require("luanphan.plugins.worktree").activate_agent
  if not valid(main) or not valid(sidebar) then return activate(session, nil, opts) end

  local windows = view_container.group_windows(main)
  vim.cmd.stopinsert()
  switching_workspace = true
  local ok, result = pcall(activate, session, windows, opts)
  switching_workspace = false
  if not ok then error(result) end
  return result
end

local function click_row()
  local mouse = vim.fn.getmousepos()
  if not valid(sidebar) or mouse.winid ~= sidebar or mouse.line < 1 then
    return "<LeftMouse>"
  end
  local row, win = rows[mouse.line], sidebar
  vim.schedule(function()
    if row and sidebar == win and valid(win) then M.select_session(row.session) end
  end)
  return ""
end

local function close_sidebar()
  local win = sidebar
  sidebar = nil
  stop_status_timer()
  if valid(main) then vim.w[main].luanphan_agent_sidebar = nil end
  if valid(win) then vim.api.nvim_win_close(win, true) end
end

local function focus_terminal()
  if not valid(main) then return end
  vim.api.nvim_set_current_win(active_terminal())
  if return_to_input then vim.cmd.startinsert() end
end

local function set_sidebar_hidden(hidden)
  vim.api.nvim_win_set_config(sidebar, { hide = hidden, focusable = not hidden, mouse = not hidden })
  refresh_statuses()
end

local function toggle_sidebar()
  if not valid(sidebar) then return end
  local hide = not vim.api.nvim_win_get_config(sidebar).hide
  if hide and vim.api.nvim_get_current_win() == sidebar then focus_terminal() end
  set_sidebar_hidden(hide)
end

function M.layout(win, width, col, height)
  if width == 0 then
    if main == win then close_sidebar() end
    return
  end
  local geometry = vim.api.nvim_win_get_config(win)
  local position = {
    relative = "editor",
    row = geometry.row,
    col = col,
    width = width,
    height = height,
    zindex = geometry.zindex,
  }
  if main == win and valid(sidebar) then
    local resized = vim.api.nvim_win_get_width(sidebar) ~= width
    vim.api.nvim_win_set_config(sidebar, position)
    if resized then M.refresh(true) end
    return
  end

  if valid(main) and main ~= win then close_window(main) end
  close_sidebar()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "agent-sidebar"
  main = win
  sidebar = vim.api.nvim_open_win(buf, false, vim.tbl_extend("force", position, {
    style = "minimal",
    border = "single",
  }))
  vim.w[main].luanphan_agent_sidebar = sidebar
  vim.w[sidebar].luanphan_view_companion_anchor = main
  vim.wo[sidebar].wrap = false
  vim.wo[sidebar].winfixbuf = true
  vim.wo[sidebar].cursorline = true
  vim.wo[sidebar].cursorlineopt = "line"
  vim.wo[sidebar].winhighlight = "CursorLine:Visual"
  vim.wo[sidebar].winbar = "%#TabLineFill# Workspaces"
  agents.map_jump_keys(buf, true)

  local opts = { buffer = buf, silent = true, nowait = true }
  local function open_selected()
    local row = selected_row()
    if row then M.select_session(row.session) end
  end
  vim.keymap.set("n", "d", function()
    local row = selected_row()
    local session = row and row.session
    if session and session.thread_id and not session.bufnr then
      agent_sessions.forget(session.agent, session.thread_id)
      M.refresh(true)
    end
  end, vim.tbl_extend("force", opts, { desc = "Forget saved agent session" }))
  for _, key in ipairs({ "<CR>", "o" }) do
    vim.keymap.set("n", key, open_selected, opts)
  end
  vim.keymap.set("n", "h", function() set_folded(true) end, opts)
  vim.keymap.set("n", "l", function() set_folded(nil) end, opts)
  vim.keymap.set("n", "J", function() move_row(1) end, opts)
  vim.keymap.set("n", "K", function() move_row(-1) end, opts)
  vim.keymap.set("n", "<LeftMouse>", click_row, vim.tbl_extend("force", opts, { expr = true }))
  vim.keymap.set("n", "<C-l>", focus_terminal, opts)
  vim.keymap.set("n", "<leader>e", focus_terminal, vim.tbl_extend("force", opts, { desc = "Focus agent terminal" }))
  vim.keymap.set("n", "<leader>b", toggle_sidebar, vim.tbl_extend("force", opts, { desc = "Toggle agent sidebar" }))
  local function close_panel()
    if valid(main) then close_window(main) end
  end
  for _, key in ipairs({ "<C-h>", "<leader>a" }) do
    vim.keymap.set("n", key, close_panel, opts)
  end

  M.refresh()
end

function M.attach(buf, win)
  local opts = { buffer = buf, silent = true, nowait = true }
  local function focus_sidebar()
    if not valid(sidebar) or not valid(win) or (main ~= win and vim.w[win].luanphan_view_anchor ~= main) then return end
    focused_terminal = win
    return_to_input = vim.api.nvim_get_mode().mode == "t"
    vim.cmd.stopinsert()
    if vim.api.nvim_win_get_config(sidebar).hide then set_sidebar_hidden(false) end
    M.refresh()
    vim.api.nvim_set_current_win(sidebar)
  end
  vim.keymap.set({ "n", "t" }, "<C-h>", focus_sidebar, opts)
  vim.keymap.set("n", "<leader>e", focus_sidebar, vim.tbl_extend("force", opts, { desc = "Focus agent sidebar" }))
  vim.keymap.set("n", "<leader>b", toggle_sidebar, vim.tbl_extend("force", opts, { desc = "Toggle agent sidebar" }))
  vim.keymap.set({ "n", "t" }, "<LeftMouse>", click_row, vim.tbl_extend("force", opts, { expr = true }))
end

local function split_focused()
  return vim.api.nvim_win_get_config(0).relative == ""
end

local group = vim.api.nvim_create_augroup("LuanphanAgentSidebar", { clear = true })
vim.api.nvim_create_autocmd("WinClosed", {
  group = group,
  callback = function(args)
    local win = tonumber(args.match)
    if win ~= main and win ~= sidebar then return end
    local anchor = main
    main, sidebar, focused_terminal = nil, nil, nil
    rows = {}
    thread_lines = {}
    stop_status_timer()
    if anchor then view_container.close_group(anchor, win) end
  end,
})

vim.api.nvim_create_autocmd("WinEnter", {
  group = group,
  callback = function()
    local current = vim.api.nvim_get_current_win()
    if main and vim.w[current].luanphan_view_anchor == main then
      focused_terminal = current
      return
    end
    if switching_workspace or not valid(main) or not split_focused() then return end
    local win = main
    vim.schedule(function()
      if win == main and not switching_workspace and valid(win) and split_focused() then
        close_window(win)
      end
    end)
  end,
})

function M.update_title(bufnr)
  local thread = thread_lines[bufnr]
  if not thread or not valid(sidebar) then return end
  local buf = vim.api.nvim_win_get_buf(sidebar)
  local line = thread.row
  local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1]
  local label = fit(require("luanphan.view_container").tab_label(bufnr, rows[line].session.agent_label), thread.title_width)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_text(buf, line - 1, thread.title_col, line - 1, #text, { label })
  vim.bo[buf].modifiable = false
end

return M
