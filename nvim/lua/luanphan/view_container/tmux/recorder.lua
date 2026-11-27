-- Keeps recent tmux pane output and repaints in memory, so a rendering drift can be replayed
-- later from :TerminalRecordDump. Recording an event stores a reference to bytes Neovim already
-- holds, so the cost per output chunk is one small table. Typed input is never recorded.
local M = {}

local SETTINGS_TTL_MS = 5000
-- Lua memory for one event table, measured; counted so max_mb also covers many tiny chunks.
local EVENT_BYTES = 256
local events, first, last, size = {}, 1, 0, 0
local enabled, limit, checked_at = false, 0, nil

local function clear()
  events, first, last, size = {}, 1, 0, 0
end

-- Settings are read at most every few seconds, never once per output chunk.
function M.reload()
  local settings = require("luanphan.global_settings").read().terminal_record
  enabled, limit = settings.enabled, settings.max_mb * 1024 * 1024
  checked_at = vim.uv.now()
  if not enabled then clear() end
end

local function drop_oldest()
  while size > limit and first <= last do
    size = size - events[first].size
    events[first], first = nil, first + 1
  end
  -- Move the remaining events to the front once the dropped prefix is large.
  if first > 4096 and first > (last - first) then
    local kept = {}
    for index = first, last do kept[#kept + 1] = events[index] end
    events, first, last = kept, 1, #kept
  end
end

local function active()
  if not checked_at or vim.uv.now() - checked_at > SETTINGS_TTL_MS then M.reload() end
  return enabled
end

function M.add(pane, kind, data, bytes)
  if not active() then return end
  last = last + 1
  bytes = (bytes or #data) + EVENT_BYTES
  events[last] = { time = vim.uv.hrtime(), pane = pane.id or "?", kind = kind, data = data, size = bytes }
  size = size + bytes
  if size > limit then drop_oldest() end
end

-- A capture keeps tmux's lines and cursor flags as they came, so a dump can rebuild tmux's state.
function M.add_capture(pane, lines, flags)
  if not active() then return end
  local bytes = 0
  for _, line in ipairs(lines) do bytes = bytes + #line + 1 end
  M.add(pane, "capture", { lines = lines, flags = flags }, bytes)
end

function M.stats()
  return { enabled = enabled, events = last - first + 1, bytes = size, limit = limit }
end

local function encode(data)
  if type(data) == "string" then return data end
  if data.lines then return table.concat(data.flags or {}, "\t") .. "\n" .. table.concat(data.lines, "\n") end
  return vim.inspect(data)
end

-- Each event is a header line `<ms since first event>\t<pane>\t<kind>\t<byte count>` followed by
-- exactly that many bytes and a newline.
function M.dump(path)
  local file, err = io.open(path, "wb")
  if not file then return nil, err end
  local start = events[first] and events[first].time or 0
  for index = first, last do
    local event = events[index]
    local data = encode(event.data)
    file:write(("%.3f\t%s\t%s\t%d\n"):format((event.time - start) / 1e6, event.pane, event.kind, #data), data, "\n")
  end
  file:close()
  return last - first + 1
end

-- Neovim resizes a terminal as soon as its window's grid changes, even when the change is undone
-- in the same tick (a winbar cleared and set again), and no autocmd reports it. A brief extra row
-- pulls a scrollback line onto the screen and shifts it away from tmux. To find the caller, the
-- window and option API calls are wrapped: each call compares the grid size of the few windows
-- showing a tmux pane before and after, and records a "trace" event with a traceback on a change.
local api = vim.api
local pane_windows = {}

local function grid(win)
  if not api.nvim_win_is_valid(win) then return nil end
  local bar = api.nvim_get_option_value("winbar", { win = win }) ~= "" and 1 or 0
  return api.nvim_win_get_width(win) .. "x" .. (api.nvim_win_get_height(win) - bar)
end

local function refresh_pane_windows()
  pane_windows = {}
  for buf, pane in pairs(vim.luanphan_tmux_panes_by_buffer or {}) do
    if api.nvim_buf_is_valid(buf) then
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do pane_windows[win] = pane end
    end
  end
end

api.nvim_create_autocmd({ "WinNew", "WinClosed", "BufWinEnter", "BufWinLeave", "TabEnter" }, {
  group = api.nvim_create_augroup("LuanphanTerminalRecordWindows", { clear = true }),
  callback = function() vim.schedule(refresh_pane_windows) end,
})

local tracing = false
-- A config reload loads this file again; wrap the original functions, not the previous wrappers.
local originals = vim.luanphan_record_api_originals or {}
vim.luanphan_record_api_originals = originals
local function wrap(name)
  originals[name] = originals[name] or api[name]
  local original = originals[name]
  api[name] = function(...)
    if tracing or next(pane_windows) == nil or not active() then return original(...) end
    tracing = true
    local before = {}
    for win in pairs(pane_windows) do before[win] = grid(win) end
    local result = { pcall(original, ...) }
    for win, pane in pairs(pane_windows) do
      local now = grid(win)
      if before[win] and now and now ~= before[win] then
        M.add(pane, "trace", ("%s win=%d %s->%s args=%s%s"):format(name, win, before[win], now,
          vim.inspect({ ... }, { newline = " ", indent = "" }):sub(1, 300), debug.traceback("", 2)))
      end
    end
    tracing = false
    if not result[1] then error(result[2], 0) end
    return unpack(result, 2, table.maxn(result))
  end
end

for _, name in ipairs({ "nvim_set_option_value", "nvim_win_set_buf", "nvim_win_set_config", "nvim_win_set_height",
  "nvim_win_set_width", "nvim_open_win", "nvim_win_close", "nvim_win_hide", "nvim_set_current_win",
  "nvim_command", "nvim_cmd", "nvim_exec2" }) do
  wrap(name)
end

vim.api.nvim_create_user_command("TerminalRecordDump", function(command)
  local path = command.args ~= "" and vim.fn.expand(command.args)
    or (vim.fn.stdpath("state") .. "/terminal-record-" .. os.date("%Y%m%d-%H%M%S") .. ".log")
  local count, err = M.dump(path)
  if not count then return vim.notify("TerminalRecordDump: " .. tostring(err), vim.log.levels.ERROR) end
  vim.notify(("TerminalRecordDump: %d events written to %s"):format(count, path))
end, { nargs = "?", complete = "file", desc = "Write recorded terminal output to a file" })

return M
