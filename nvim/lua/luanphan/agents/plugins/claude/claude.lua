-- The terminal title carries the session state: "◐ name"/"◑ name" alternate while working and
-- "✳ name" means idle or waiting for input (">" and "*" when only ASCII is allowed).
local M = {
  icon = "\u{ec82}",
  plugin = "luanphan-claude-agent",
  status = { initial = "idle" },
  defaults = { cmd = "mclaude" },
}

local working = { ["◐"] = true, ["◑"] = true, [">"] = true }
local resting = { ["✳"] = true, ["*"] = true }

function M.display_title(title)
  if type(title) ~= "string" then return title end
  local prefix, name = title:match("^(%S+) (.*)$")
  if working[prefix] then return name, "working" end
  if resting[prefix] then return name, "idle" end
  return title
end

function M.decode_event(bufnr, event, emit)
  if not event.title then return end
  local name, status = M.display_title(event.title)
  if not status then return emit({ refresh_title = true }) end
  local buf = vim.b[bufnr]
  -- Coming to rest after work means the turn finished.
  if status == "idle" and (buf.luanphan_view_status == "working" or buf.luanphan_view_status == "done") then status = "done" end
  emit({ status = status })
  -- The prefix animates every second; only a new name needs the bar redrawn.
  if buf.luanphan_claude_title == name then return end
  buf.luanphan_claude_title = name
  emit({ refresh_title = true })
end

return M
