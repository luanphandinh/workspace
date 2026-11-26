-- Window state of a mirrored tmux pane: where its window is scrolled, whether it follows live
-- output, and where the cursor goes after a paint.
local M = {}
local api = vim.api

function M.showing(pane, win)
  return win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == pane.bufnr
end

function M.is_visible(pane)
  return M.showing(pane, pane.view_win)
end

function M.restore_pending(pane)
  if not pane.pending_view or pane.view_pending then return end
  pane.view_pending = true
  vim.schedule(function()
    local pending = pane.pending_view
    pane.pending_view, pane.view_pending = nil, false
    if pending and pane.view_win == pending.win and pane.client == pending.client
      and (not pending.frame or pane.frame == pending.frame)
      and M.showing(pane, pending.win) then
      M.apply_view(pane, pending.win, pending.cursor)
    end
  end)
end

function M.queue_cursor(pane, cursor, frame)
  if not pane.view_win then return end
  local pending = { cursor = cursor, frame = frame, win = pane.view_win, client = pane.client }
  pane.pending_view = pending
  -- A cursor-only frame can leave the terminal buffer text untouched.
  vim.defer_fn(function()
    if pane.pending_view == pending then M.restore_pending(pane) end
  end, 20)
end

function M.live_topline(pane)
  return math.max(1, api.nvim_buf_line_count(pane.bufnr) - pane.view_height + 1)
end

function M.save_view(pane, win)
  if not pane.view_height or pane.pending_view or not M.showing(pane, win) then return end
  pane.last_view = api.nvim_win_call(win, vim.fn.winsaveview)
  pane.follow_live = pane.last_view.topline >= M.live_topline(pane)
end

function M.hide_view(pane)
  M.save_view(pane, pane.view_win)
  pane.view_win, pane.pending_view, pane.cursor_request = nil, nil, nil
end

function M.restore(pane, win)
  if pane.view_win == win then return end
  pane.view_win = win
  local follow = pane.hidden_output and pane.follow_live ~= false
  pane.hidden_output = nil
  if pane.last_view and not follow then
    M.apply_view(pane, win, pane.last_view)
  elseif pane.ready and pane.frame and pane.frame.width == pane.view_width and pane.frame.height == pane.view_height then
    M.queue_cursor(pane, pane.frame, pane.frame)
  elseif pane.ready and follow and pane.client then
    local client, request = pane.client, {}
    pane.cursor_request = request
    client:request({ "display-message", "-p", "-t", pane.id, "#{cursor_y}\t#{cursor_x}" }, function(ok, lines)
      if not ok or pane.client ~= client or pane.cursor_request ~= request or not M.showing(pane, win) then return end
      pane.cursor_request = nil
      local row, col = (lines[1] or ""):match("^(%d+)\t(%d+)$")
      if row then M.queue_cursor(pane, { row = tonumber(row), col = tonumber(col) }) end
    end)
  end
end

function M.apply_view(pane, win, view)
  api.nvim_win_call(win, function()
    if view.topline then return vim.fn.winrestview(view) end
    local line_count = api.nvim_buf_line_count(pane.bufnr)
    local top = M.live_topline(pane)
    local line = math.min(line_count, top + view.row)
    local col = math.max(0, vim.fn.virtcol2col(win, line, view.col + 1) - 1)
    vim.fn.winrestview({ topline = top, lnum = line, col = col, leftcol = 0 })
  end)
end

return M
