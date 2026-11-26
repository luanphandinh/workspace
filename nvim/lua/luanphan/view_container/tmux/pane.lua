local M = {}
local api = vim.api
local screen = require("luanphan.view_container.tmux.screen")
-- Agent buffers can outlive a config reload.
local panes_by_buffer = vim.luanphan_tmux_panes_by_buffer or setmetatable({}, { __mode = "v" })
vim.luanphan_tmux_panes_by_buffer = panes_by_buffer
local history_position = "#{?#{!=:#{history_added},},#{history_added},#{history_size}}"
local cursor_format = "#{cursor_x}\t#{cursor_y}\t#{alternate_on}\t#{cursor_flag}"
  .. "\t#{keypad_cursor_flag}\t#{bracket_paste_flag}\t" .. history_position
  .. "\t#{pane_width}\t#{pane_height}\t#{history_generation}"

function M.for_buffer(buf)
  return panes_by_buffer[buf]
end

local function showing(pane, win)
  return win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == pane.bufnr
end

function M.is_visible(pane)
  return showing(pane, pane.view_win)
end

local function restore_pending_view(pane)
  if not pane.pending_view or pane.view_pending then return end
  pane.view_pending = true
  vim.schedule(function()
    local pending = pane.pending_view
    pane.pending_view, pane.view_pending = nil, false
    if pending and pane.view_win == pending.win and pane.client == pending.client
      and (not pending.frame or pane.frame == pending.frame)
      and showing(pane, pending.win) then
      M.apply_view(pane, pending.win, pending.cursor)
    end
  end)
end

local function queue_cursor(pane, cursor, frame)
  if not pane.view_win then return end
  local pending = { cursor = cursor, frame = frame, win = pane.view_win, client = pane.client }
  pane.pending_view = pending
  -- A cursor-only frame can leave the terminal buffer text untouched.
  vim.defer_fn(function()
    if pane.pending_view == pending then restore_pending_view(pane) end
  end, 20)
end

function M.input(pane, data)
  local client = pane.client
  if not client or not client.job or pane.receiving then return false end
  pane.input = (pane.input or "") .. data
  if pane.input_pending then return true end
  pane.input_pending = true
  vim.schedule(function()
    local bytes = pane.input
    pane.input, pane.input_pending = nil, nil
    if pane.client ~= client or not client.job then return end
    for start = 1, #bytes, 512 do
      local args = { "send-keys", "-H", "-t", pane.id }
      for index = start, math.min(start + 511, #bytes) do
        args[#args + 1] = ("%02x"):format(bytes:byte(index))
      end
      client:request(args)
    end
  end)
  return true
end

function M.open(pane, on_input)
  pane.term = api.nvim_open_term(pane.bufnr, {
    force_crlf = false,
    on_input = function(_, _, _, data)
      -- tmux owns focus reporting for its panes.
      if pane.receiving or data == "\27[I" or data == "\27[O" then return end
      if on_input then on_input(data) end
      M.input(pane, data)
    end,
  })
  panes_by_buffer[pane.bufnr] = pane
  api.nvim_buf_attach(pane.bufnr, false, { on_lines = function() restore_pending_view(pane) end })
  api.nvim_create_autocmd({ "WinLeave", "BufWinLeave" }, {
    buffer = pane.bufnr,
    callback = function(event)
      if event.event == "BufWinLeave" then
        M.hide_view(pane)
      elseif api.nvim_get_current_win() == pane.view_win then
        M.save_view(pane, pane.view_win)
      end
    end,
  })
end

function M.output(pane, bytes)
  if not pane.term or not api.nvim_buf_is_valid(pane.bufnr) then return end
  pane.receiving = true
  api.nvim_chan_send(pane.term, bytes)
  pane.receiving = false
end

function M.stream(pane, bytes)
  if not pane.view_win then pane.hidden_output = true end
  pane.frame = nil
  M.output(pane, bytes)
  -- Neovim can drift from tmux on some redraws; resync visible rows once output settles.
  local token = (pane.settle or 0) + 1
  pane.settle = token
  vim.defer_fn(function()
    if pane.settle == token and pane.ready and not pane.resizing and M.is_visible(pane) then
      M.paint(pane, M.is_visible)
    end
  end, 100)
end

-- Returns the start of an escape sequence or UTF-8 character that the next output chunk completes.
local function unfinished_tail(data)
  local start = data:match(".*()\27")
  if start then
    local kind = data:sub(start + 1, start + 1)
    local rest = data:sub(start + 1)
    if kind == "" or (kind == "[" and rest:find("^%[[\48-\63]*[\32-\47]*$"))
      or (kind:find("^[%]P_%^X]") and not rest:find("\7", 2, true))
      or (kind:find("^[\32-\47]") and rest:find("^[\32-\47]*$")) then
      return #data - start < 65536 and data:sub(start) or ""
    end
  end
  for back = 1, math.min(3, #data) do
    local byte = data:byte(#data - back + 1)
    if byte >= 0xC0 then
      local size = byte >= 0xF0 and 4 or byte >= 0xE0 and 3 or 2
      return size > back and data:sub(-back) or ""
    elseif byte < 0x80 then
      break
    end
  end
  return ""
end

-- A snapshot restores the screen, but tmux does not include OSC events in it.
local function replay_osc(pane, bytes)
  local pending = (pane.pending_osc or "") .. bytes
  while true do
    local start_at = pending:find("\27]", 1, true)
    if not start_at then
      pane.pending_osc = pending:sub(-1) == "\27" and "\27" or nil
      return
    end
    local bell = pending:find("\7", start_at + 2, true)
    local st = pending:find("\27\\", start_at + 2, true)
    local last = (st and (not bell or st < bell)) and st + 1 or bell
    if not last then
      pane.pending_osc = #pending - start_at < 65536 and pending:sub(start_at) or nil
      return
    end
    M.output(pane, pending:sub(start_at, last))
    pending = pending:sub(last + 1)
  end
end

function M.receive(pane, bytes)
  if not pane then return end
  pane.tail = unfinished_tail((pane.tail or "") .. bytes)
  -- Retry a rebuild that could not paint right after the resize.
  if pane.ready and pane.rebuild then
    if pane.repaint then pane.repaint(pane) else M.paint(pane) end
  end
  if pane.ready then return M.stream(pane, bytes) end
  if pane.capturing or pane.replay_osc then pane.dirty = true end
  if pane.replay_osc then replay_osc(pane, bytes) end
end

function M.grid_size(win)
  local height = api.nvim_win_get_height(win) - (vim.wo[win].winbar == "" and 0 or 1)
  return math.max(1, api.nvim_win_get_width(win)), math.max(1, height)
end

local function sync_grid(pane, win)
  local width, height = M.grid_size(win)
  pane.view_width, pane.view_height = width, height
  local client, pending = pane.client, pane.resizing
  if not client or not client.job then return end
  if pending and pending.client == client then
    if pending.width == width and pending.height == height then return end
  elseif pane.width == width and pane.height == height then
    pane.resizing = nil
    return
  end
  local request = { client = client, width = width, height = height }
  pane.resizing = request
  client:request({ "resize-window", "-t", pane.window, "-x", tostring(width), "-y", tostring(height) }, function(ok)
    if pane.client ~= client then return end
    if ok then
      -- Neovim and tmux rewrap differently, so rebuild the copy from tmux.
      if pane.width ~= width then pane.rebuild = true end
      pane.width, pane.height = width, height
    end
    if pane.resizing ~= request then return end
    pane.resizing = nil
    if pane.repaint then pane.repaint(pane) elseif pane.rebuild then M.paint(pane) end
  end)
end

function M.live_topline(pane)
  return math.max(1, api.nvim_buf_line_count(pane.bufnr) - pane.view_height + 1)
end

function M.save_view(pane, win)
  if not pane.view_height or pane.pending_view or not showing(pane, win) then return end
  pane.last_view = api.nvim_win_call(win, vim.fn.winsaveview)
  pane.follow_live = pane.last_view.topline >= M.live_topline(pane)
end

function M.hide_view(pane)
  M.save_view(pane, pane.view_win)
  pane.view_win, pane.pending_view, pane.cursor_request = nil, nil, nil
end

local function restore_view(pane, win)
  if pane.view_win == win then return end
  pane.view_win = win
  local follow = pane.hidden_output and pane.follow_live ~= false
  pane.hidden_output = nil
  if pane.last_view and not follow then
    M.apply_view(pane, win, pane.last_view)
  elseif pane.ready and pane.frame and pane.frame.width == pane.view_width and pane.frame.height == pane.view_height then
    queue_cursor(pane, pane.frame, pane.frame)
  elseif pane.ready and follow and pane.client then
    local client, request = pane.client, {}
    pane.cursor_request = request
    client:request({ "display-message", "-p", "-t", pane.id, "#{cursor_y}\t#{cursor_x}" }, function(ok, lines)
      if not ok or pane.client ~= client or pane.cursor_request ~= request or not showing(pane, win) then return end
      pane.cursor_request = nil
      local row, col = (lines[1] or ""):match("^(%d+)\t(%d+)$")
      if row then queue_cursor(pane, { row = tonumber(row), col = tonumber(col) }) end
    end)
  end
end

function M.show_view(pane, win)
  sync_grid(pane, win)
  restore_view(pane, win)
  if pane.repaint then pane.repaint(pane) end
end

function M.resolve_hyperlink(buf, row, column, callback)
  local pane = panes_by_buffer[buf]
  local client = pane and pane.client
  if not client or not client.ready or not client.job or row < 1 or column < 1 then return false end
  local visible = api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  if not visible or column > #visible then return false end

  local frame, width = pane.frame, pane.view_width
  local topline = M.live_topline(pane)
  local tmux_row = tostring(row - topline + (frame and frame.top or 0))
  client:request({ "capture-pane", "-epN", "-t", pane.id, "-S", tmux_row, "-E", tmux_row }, function(ok, lines)
    if not ok or not lines[1] or pane.client ~= client or pane.frame ~= frame or pane.view_width ~= width
      or not api.nvim_buf_is_valid(buf) or topline ~= M.live_topline(pane)
      or api.nvim_buf_get_lines(buf, row - 1, row, false)[1] ~= visible then
      return callback()
    end
    callback(screen.hyperlink_at(lines[1], frame and frame.left or 0, width, visible, column))
  end)
  return true
end

local function capture_start(pane)
  if not pane.painted then return tostring(-(pane.history_limit or 1000)) end
  local frame = pane.frame
  if not frame or frame.alternate then return "0" end
  -- Capture rows that moved above the previous live viewport.
  local offset = ("#{e|-:%d,%s}"):format(frame.history + frame.top, history_position)
  return ("#{?#{m:-*,%s},%s,0}"):format(offset, offset)
end

function M.capture(pane, callback)
  local capture = { "capture-pane", "-epN", "-t", pane.id, "-S", capture_start(pane) }
  local restore_primary = pane.restore_primary and not pane.painted
  local format = restore_primary and cursor_format .. "\t#{alternate_saved_x}\t#{alternate_saved_y}" or cursor_format
  local commands = { capture, { "display-message", "-p", "-t", pane.id, format } }
  if restore_primary then commands[3] = { "capture-pane", "-aepNq", "-t", pane.id } end
  pane.client:request_batch(commands, function(replies)
    local content, cursor, primary = unpack(replies)
    if not content.ok or not cursor.ok then return callback() end
    local flags = vim.split(cursor.lines[1] or "", "\t", { plain = true })
    callback(content.lines, flags, primary and primary.ok and primary.lines or nil)
  end)
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

function M.frame(pane, lines, flags, primary)
  local saved_screen = ""
  if flags[3] == "1" and primary and #primary > 0 then
    -- tmux captures primary history with the live alternate grid and saves the primary grid separately.
    local history_end = math.max(0, #lines - (tonumber(flags[9]) or pane.height))
    local saved_lines = vim.list_extend(vim.list_slice(lines, 1, history_end), primary)
    local saved_flags = vim.list_slice(flags, 1, 10)
    saved_flags[1], saved_flags[2], saved_flags[3], saved_flags[9] = flags[11], flags[12], "0", tostring(#primary)
    pane.frame, saved_screen = screen.frame(pane, saved_lines, saved_flags)
    pane.painted = true
  end
  local frame, output = screen.frame(pane, lines, flags)
  return frame, saved_screen .. output
end

function M.paint_frame(pane, lines, flags, primary)
  local first = not pane.painted
  local frame, output = M.frame(pane, lines, flags, primary)
  local in_input = api.nvim_get_current_buf() == pane.bufnr and api.nvim_get_mode().mode == "t"
  pane.frame, pane.painted = frame, true
  if (first and pane.follow_live ~= false) or (in_input and output ~= "") then
    queue_cursor(pane, frame, frame)
  end
  if output ~= "" then M.output(pane, output) end
end

function M.paint(pane, visible)
  if not pane.term or not pane.client or pane.capturing or (visible and not visible(pane)) then return end
  local connection = pane.client
  -- Cancel a sequence Neovim is still parsing before painting over it.
  if pane.ready and (pane.tail or "") ~= "" then M.output(pane, "\24") end
  local win, view = pane.view_win, nil
  if pane.rebuild then
    if M.is_visible(pane) and api.nvim_win_call(win, function() return vim.fn.line("w0") end) < M.live_topline(pane) then
      view, pane.follow_live = api.nvim_win_call(win, vim.fn.winsaveview), false
    end
    pane.rebuild, pane.painted, pane.frame = nil, false, nil
    M.output(pane, "\27[3J")
  end
  pane.capturing, pane.ready, pane.dirty = true, false, false
  M.capture(pane, function(lines, flags, primary)
    if pane.client ~= connection then return end
    pane.capturing = false
    if not lines or (visible and not visible(pane)) then return end
    M.paint_frame(pane, lines, flags, primary)
    if view and showing(pane, win) then M.apply_view(pane, win, view) end
    if pane.dirty or pane.rebuild then
      M.paint(pane, visible)
      return
    end
    pane.ready = true
    pane.pending_osc = nil
    -- tmux is still waiting for the rest of this sequence, so Neovim must wait for it too.
    if (pane.tail or "") ~= "" then M.output(pane, pane.tail) end
  end)
end

return M
