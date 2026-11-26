-- Keeps recent tmux pane output and repaints in memory, so a rendering drift can be replayed
-- later from :TerminalRecordDump. Recording an event stores a reference to bytes Neovim already
-- holds, so the cost per output chunk is one small table. Typed input is never recorded.
local M = {}

local SETTINGS_TTL_MS = 5000
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
  bytes = bytes or #data
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

vim.api.nvim_create_user_command("TerminalRecordDump", function(command)
  local path = command.args ~= "" and vim.fn.expand(command.args)
    or (vim.fn.stdpath("state") .. "/terminal-record-" .. os.date("%Y%m%d-%H%M%S") .. ".log")
  local count, err = M.dump(path)
  if not count then return vim.notify("TerminalRecordDump: " .. tostring(err), vim.log.levels.ERROR) end
  vim.notify(("TerminalRecordDump: %d events written to %s"):format(count, path))
end, { nargs = "?", complete = "file", desc = "Write recorded terminal output to a file" })

return M
