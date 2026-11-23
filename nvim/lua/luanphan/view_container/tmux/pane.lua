local M = {}
local api = vim.api
local screen = require("luanphan.view_container.tmux.screen")
local history_position = "#{?#{!=:#{history_added},},#{history_added},#{history_size}}"
local cursor_format = "#{cursor_x}\t#{cursor_y}\t#{alternate_on}\t#{cursor_flag}"
  .. "\t#{keypad_cursor_flag}\t#{bracket_paste_flag}\t" .. history_position
  .. "\t#{pane_width}\t#{pane_height}\t#{history_generation}"

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
end

function M.output(pane, bytes)
  if not pane.term or not api.nvim_buf_is_valid(pane.bufnr) then return end
  pane.receiving = true
  api.nvim_chan_send(pane.term, bytes)
  pane.receiving = false
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

function M.live_topline(pane)
  return math.max(1, api.nvim_buf_line_count(pane.bufnr) - pane.view_height + 1)
end

function M.apply_view(pane, win, view)
  api.nvim_win_call(win, function()
    if view.topline then return vim.fn.winrestview(view) end
    local top = M.live_topline(pane)
    local line = math.min(api.nvim_buf_line_count(pane.bufnr), top + view.row)
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

return M
