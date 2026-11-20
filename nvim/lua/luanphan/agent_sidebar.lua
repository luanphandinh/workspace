local M = {}
local close_window = require("luanphan.terminal_agent").close_window

local main, sidebar
local rows = {}
local thread_lines = {}
local return_to_input = false
local switching_workspace = false
local ns = vim.api.nvim_create_namespace("LuanphanAgentSidebar")
local tree_indent = #"  ├─ "

local function valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

function M.refresh()
  if not valid(sidebar) or not valid(main) then return end
  local sessions = require("luanphan.plugins.worktree").list_agent_sessions()
  local groups = {}
  for _, session in ipairs(sessions) do
    groups[session.workspace] = groups[session.workspace] or {}
    table.insert(groups[session.workspace], session)
  end

  local workspaces = vim.tbl_keys(groups)
  table.sort(workspaces)
  local active = vim.api.nvim_win_get_buf(main)
  local lines = {}
  local active_row
  rows = {}
  thread_lines = {}
  for _, workspace in ipairs(workspaces) do
    local threads = groups[workspace]
    table.sort(threads, function(a, b) return a.bufnr < b.bufnr end)
    lines[#lines + 1] = "▾ " .. vim.fn.fnamemodify(workspace, ":t")
    local heading = #lines
    local recent = threads[1]
    for index, thread in ipairs(threads) do
      local branch = index == #threads and "└─ " or "├─ "
      lines[#lines + 1] = "  " .. branch .. thread.agent_label
      rows[#lines] = thread
      thread_lines[thread.bufnr] = #lines
      if thread.bufnr == active then active_row = #lines end
      if thread.last_used > recent.last_used then recent = thread end
    end
    rows[heading] = recent
  end

  local buf = vim.api.nvim_win_get_buf(sidebar)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if active_row then
    vim.api.nvim_buf_set_extmark(buf, ns, active_row - 1, 0, { line_hl_group = "Title" })
    vim.api.nvim_win_set_cursor(sidebar, { active_row, 0 })
  end
end

function M.select_session(session, opts)
  if not session then return false end
  local activate = require("luanphan.plugins.worktree").activate_agent
  if not valid(main) or not valid(sidebar) then return activate(session, nil, opts) end

  vim.cmd.stopinsert()
  switching_workspace = true
  local ok, result = pcall(activate, session, { main, sidebar }, opts)
  switching_workspace = false
  if not ok then error(result) end
  return result
end

local function click_row()
  local mouse = vim.fn.getmousepos()
  if not valid(sidebar) or mouse.winid ~= sidebar or mouse.line < 1 then
    return "<LeftMouse>"
  end
  local session, win = rows[mouse.line], sidebar
  vim.schedule(function()
    if sidebar == win and valid(win) then M.select_session(session) end
  end)
  return ""
end

local function close_sidebar()
  local win = sidebar
  sidebar = nil
  if valid(main) then vim.w[main].luanphan_agent_sidebar = nil end
  if valid(win) then vim.api.nvim_win_close(win, true) end
end

local function focus_terminal()
  if not valid(main) then return end
  vim.api.nvim_set_current_win(main)
  if return_to_input then vim.cmd.startinsert() end
end

local function set_sidebar_hidden(hidden)
  vim.api.nvim_win_set_config(sidebar, { hide = hidden, focusable = not hidden, mouse = not hidden })
end

local function toggle_sidebar()
  if not valid(sidebar) then return end
  local hide = not vim.api.nvim_win_get_config(sidebar).hide
  if hide and vim.api.nvim_get_current_win() == sidebar then focus_terminal() end
  set_sidebar_hidden(hide)
end

function M.layout(win, width)
  if width == 0 then
    if main == win then close_sidebar() end
    return
  end
  local geometry = vim.api.nvim_win_get_config(win)
  local position = {
    relative = "editor",
    row = geometry.row,
    col = geometry.col - width - 3,
    width = width,
    height = geometry.height,
    zindex = geometry.zindex,
  }
  if main == win and valid(sidebar) then
    vim.api.nvim_win_set_config(sidebar, position)
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
  vim.wo[sidebar].wrap = false
  vim.wo[sidebar].cursorline = true
  vim.wo[sidebar].cursorlineopt = "line"
  vim.wo[sidebar].winhighlight = "CursorLine:Visual"
  vim.wo[sidebar].winbar = "%#TabLineFill# Workspaces"

  local opts = { buffer = buf, silent = true, nowait = true }
  local function open_selected()
    M.select_session(rows[vim.api.nvim_win_get_cursor(sidebar)[1]])
  end
  for _, key in ipairs({ "<CR>", "o" }) do
    vim.keymap.set("n", key, open_selected, opts)
  end
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
  if vim.api.nvim_win_get_config(win).relative == "" then
    for _, mode in ipairs({ "n", "t" }) do
      pcall(vim.keymap.del, mode, "<LeftMouse>", { buffer = buf })
    end
    for _, key in ipairs({ "<leader>e", "<leader>b" }) do
      pcall(vim.keymap.del, "n", key, { buffer = buf })
    end
    return
  end
  local function focus_sidebar()
    if main ~= win or not valid(sidebar) then return end
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
  M.refresh()
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
    local closing_main = win == main
    local other = sidebar
    if not closing_main then other = main end
    main, sidebar = nil, nil
    rows = {}
    thread_lines = {}
    if valid(other) then vim.api.nvim_win_close(other, closing_main) end
  end,
})

vim.api.nvim_create_autocmd("WinEnter", {
  group = group,
  callback = function()
    if switching_workspace or not valid(main) or not split_focused() then return end
    local win = main
    vim.schedule(function()
      if win == main and not switching_workspace and valid(win) and split_focused() then
        close_window(win)
      end
    end)
  end,
})

vim.api.nvim_create_autocmd("TermRequest", {
  group = group,
  callback = function(args)
    local sequence = args.data and args.data.sequence
    if not thread_lines[args.buf] or not sequence or not sequence:match("^\27%][02];") then return end
    vim.schedule(function()
      local line = thread_lines[args.buf]
      if not line or not valid(sidebar) or not vim.api.nvim_buf_is_valid(args.buf) then return end
      local buf = vim.api.nvim_win_get_buf(sidebar)
      local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1]
      local label = require("luanphan.view_container").tab_label(args.buf, rows[line].agent_label)
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_text(buf, line - 1, tree_indent, line - 1, #text, { label })
      vim.bo[buf].modifiable = false
    end)
  end,
})

return M
