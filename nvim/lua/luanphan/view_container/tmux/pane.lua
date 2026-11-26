-- Mirrors a tmux pane into a Neovim terminal buffer: live output is streamed as it arrives,
-- and the pane is repainted from a tmux capture on attach, resize, or when the copies drift.
-- Window scroll and cursor state lives in tmux/view.lua.
local M = {}
local api = vim.api
local screen = require("luanphan.view_container.tmux.screen")
local view = require("luanphan.view_container.tmux.view")
-- Agent buffers can outlive a config reload.
local panes_by_buffer = vim.luanphan_tmux_panes_by_buffer or setmetatable({}, { __mode = "v" })
vim.luanphan_tmux_panes_by_buffer = panes_by_buffer
local history_position = "#{?#{!=:#{history_added},},#{history_added},#{history_size}}"
local cursor_format = "#{cursor_x}\t#{cursor_y}\t#{alternate_on}\t#{cursor_flag}"
  .. "\t#{keypad_cursor_flag}\t#{bracket_paste_flag}\t" .. history_position
  .. "\t#{pane_width}\t#{pane_height}\t#{history_generation}"
  .. "\t#{mouse_standard_flag}\t#{mouse_button_flag}\t#{mouse_any_flag}\t#{mouse_sgr_flag}"
  .. "\t#{scroll_region_upper}\t#{scroll_region_lower}"
local saved_cursor_field = 17

M.is_visible, M.live_topline, M.save_view, M.hide_view, M.apply_view =
  view.is_visible, view.live_topline, view.save_view, view.hide_view, view.apply_view

function M.for_buffer(buf)
  return panes_by_buffer[buf]
end

-- Neovim sizes a terminal to the smallest window showing it. A new width rewraps lines,
-- and a new height moves lines between the screen and scrollback differently from tmux.
local function terminal_size(buf)
  local width, height
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local info = vim.fn.getwininfo(win)[1]
    width = math.min(width or math.huge, info.width - info.textoff)
    height = math.min(height or math.huge, info.height)
  end
  return width, height
end

local function mark_resized(pane, width, height)
  if pane.width and width ~= pane.width then
    pane.rebuild = true
  elseif pane.height and height ~= pane.height then
    pane.resync = true
  end
end

-- Coalesces refresh requests, so a window drag or an output burst paints once.
local function request_refresh(pane)
  if pane.refresh_queued then return end
  pane.refresh_queued = true
  vim.defer_fn(function()
    pane.refresh_queued = nil
    if not pane.ready or not (pane.rebuild or pane.resync) then return end
    if pane.repaint then pane.repaint(pane) else M.paint(pane) end
  end, 50)
end

-- A split or another window showing the buffer rewraps Neovim's copy, so rebuild it from tmux.
api.nvim_create_autocmd({ "WinNew", "WinResized", "BufWinEnter", "WinClosed" }, {
  group = api.nvim_create_augroup("LuanphanTmuxTerminalSize", { clear = true }),
  callback = function()
    -- Check right away: a split can be replaced before a scheduled check would see it.
    for buf, pane in pairs(panes_by_buffer) do
      if api.nvim_buf_is_valid(buf) then
        local width, height = terminal_size(buf)
        if width and (width ~= pane.term_width or height ~= pane.term_height) then
          if pane.term_width then
            if width ~= pane.term_width then pane.rebuild = true else pane.resync = true end
            -- Hidden panes refresh when they are shown again.
            if view.is_visible(pane) then request_refresh(pane) end
          end
          pane.term_width, pane.term_height = width, height
        end
      end
    end
  end,
})

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
  api.nvim_buf_attach(pane.bufnr, false, { on_lines = function() view.restore_pending(pane) end })
  api.nvim_create_autocmd({ "WinLeave", "BufWinLeave" }, {
    buffer = pane.bufnr,
    callback = function(event)
      if event.event == "BufWinLeave" then
        view.hide_view(pane)
      elseif api.nvim_get_current_win() == pane.view_win then
        view.save_view(pane, pane.view_win)
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
  if pane.ready then
    M.stream(pane, bytes)
    -- Retry a refresh that could not paint right after the resize.
    if pane.rebuild or pane.resync then request_refresh(pane) end
    return
  end
  -- tmux sends output that came before a capture ahead of the capture's reply, so the capture
  -- already includes these bytes.
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
      -- Neovim and tmux resize their screens differently, so refresh the copy from tmux.
      mark_resized(pane, width, height)
      pane.width, pane.height = width, height
    end
    if pane.resizing ~= request then return end
    pane.resizing = nil
    if pane.rebuild or pane.resync then request_refresh(pane) elseif pane.repaint then pane.repaint(pane) end
  end)
end

function M.show_view(pane, win)
  if not pane.term_width then pane.term_width, pane.term_height = terminal_size(pane.bufnr) end
  sync_grid(pane, win)
  view.restore(pane, win)
  if pane.repaint then pane.repaint(pane) elseif (pane.rebuild or pane.resync) and not pane.resizing then M.paint(pane) end
end

function M.resolve_hyperlink(buf, row, column, callback)
  local pane = panes_by_buffer[buf]
  local client = pane and pane.client
  if not client or not client.ready or not client.job or row < 1 or column < 1 then return false end
  local visible = api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  if not visible or column > #visible then return false end

  local frame, width = pane.frame, pane.view_width
  local topline = view.live_topline(pane)
  local tmux_row = tostring(row - topline + (frame and frame.top or 0))
  client:request({ "capture-pane", "-epN", "-t", pane.id, "-S", tmux_row, "-E", tmux_row }, function(ok, lines)
    if not ok or not lines[1] or pane.client ~= client or pane.frame ~= frame or pane.view_width ~= width
      or not api.nvim_buf_is_valid(buf) or topline ~= view.live_topline(pane)
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

function M.frame(pane, lines, flags, primary)
  local saved_screen = ""
  if flags[3] == "1" and primary and #primary > 0 then
    -- tmux captures primary history with the live alternate grid and saves the primary grid separately.
    local history_end = math.max(0, #lines - (tonumber(flags[9]) or pane.height))
    local saved_lines = vim.list_extend(vim.list_slice(lines, 1, history_end), primary)
    local saved_flags = vim.list_slice(flags, 1, saved_cursor_field - 1)
    saved_flags[1], saved_flags[2], saved_flags[3], saved_flags[9] =
      flags[saved_cursor_field], flags[saved_cursor_field + 1], "0", tostring(#primary)
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
    view.queue_cursor(pane, frame, frame)
  end
  -- Neovim applies a scrollback clear on its next refresh, so a clear sent before the capture
  -- could also wipe history written after it.
  if pane.clear_scrollback then output, pane.clear_scrollback = "\27[3J" .. output, nil end
  if output ~= "" then M.output(pane, output) end
end

function M.paint(pane, visible)
  if not pane.term or not pane.client or pane.capturing or (visible and not visible(pane)) then return end
  -- The resize callback refreshes the pane once tmux has the new size.
  if pane.resizing and pane.resizing.client == pane.client then return end
  local connection = pane.client
  -- Cancel a sequence Neovim is still parsing before painting over it.
  if pane.ready and (pane.tail or "") ~= "" then M.output(pane, "\24") end
  local win, scrolled = pane.view_win, nil
  if pane.rebuild then
    if pane.follow_live == false and view.is_visible(pane) then scrolled = api.nvim_win_call(win, vim.fn.winsaveview) end
    -- The scrollback is cleared in the same write as the new history (see paint_frame).
    pane.rebuild, pane.painted, pane.frame, pane.clear_scrollback = nil, false, nil, true
  end
  -- Without a previous frame, the paint rewrites every visible row and the cursor.
  if pane.resync then pane.resync, pane.frame = nil, nil end
  pane.capturing, pane.ready = true, false
  M.capture(pane, function(lines, flags, primary)
    if pane.client ~= connection then return end
    pane.capturing = false
    if not lines then
      -- Keep streaming and retry on the next output instead of freezing the pane.
      if pane.painted then pane.resync = true else pane.rebuild = true end
      pane.ready = true
      return
    end
    if visible and not visible(pane) then return end
    M.paint_frame(pane, lines, flags, primary)
    -- Restore the scrolled view once Neovim has refreshed the rebuilt buffer.
    if scrolled and view.showing(pane, win) then view.queue_cursor(pane, scrolled, pane.frame) end
    pane.ready = true
    if pane.rebuild or pane.resync then request_refresh(pane) end
    pane.pending_osc = nil
    -- tmux is still waiting for the rest of this sequence, so Neovim must wait for it too.
    if (pane.tail or "") ~= "" then M.output(pane, pane.tail) end
  end)
end

return M
