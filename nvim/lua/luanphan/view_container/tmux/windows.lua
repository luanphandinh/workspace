local M = {}
local option = "@luanphan-view-window"

M.format = table.concat({
  "#{window_id}", "#{window_index}", "#{window_active}", "#{pane_id}", "#{pane_active}",
  "#{pane_index}", "#{pane_width}", "#{pane_height}", "#{pane_current_command}",
  "#{window_name}", "#{history_limit}", "#{" .. option .. "}", "#{pane_current_path}",
}, "\t")

function M.read(lines)
  local records = {}
  for _, line in ipairs(lines) do
    local field = vim.split(line, "\t", { plain = true })
    if field[4] and field[4]:match("^%%%d+$") then
      local ok, data = pcall(vim.json.decode, field[12])
      if not ok or type(data) ~= "table" or type(data.group) ~= "string" or not data.group:match("^@%d+$")
        or type(data.title) ~= "string" or type(data.window_order) ~= "number"
        or type(data.pane_order) ~= "number" then
        data = nil
      end
      records[#records + 1] = {
        id = field[4], window = field[1], window_order = tonumber(field[2]),
        selected = field[3] == "1" and field[5] == "1", active = field[5] == "1",
        pane_order = tonumber(field[6]), width = tonumber(field[7]), height = tonumber(field[8]),
        label = field[9] ~= "" and field[9] or "shell", title = field[10],
        history_limit = tonumber(field[11]), data = data, cwd = table.concat(field, "\t", 13),
      }
    end
  end
  return records
end

function M.write(pane, changes)
  local data = vim.tbl_extend("force", pane.data, changes or {})
  return { "set-option", "-p", "-t", pane.id, option, vim.json.encode(data) }
end

function M.rename(window, title)
  return { "rename-window", "-t", window, "--", (title:gsub("#", "##")) }
end

function M.migrate(records)
  local by_id, windows, last_order, commands = {}, {}, {}, {}
  local newest_window
  for _, pane in ipairs(records) do
    local group = by_id[pane.window]
    if not group then
      group = { panes = {}, index = pane.window_order }
      by_id[pane.window] = group
      windows[#windows + 1] = group
    end
    group.panes[#group.panes + 1] = pane
    if pane.data then
      local data = pane.data
      group.data = data
      last_order[data.group] = math.max(last_order[data.group] or 0, data.pane_order)
      newest_window = math.max(newest_window or 0, data.window_order)
    end
  end
  table.sort(windows, function(a, b) return a.index < b.index end)
  for _, group in ipairs(windows) do
    local window_order = group.data and group.data.window_order or group.index
    if not group.data and newest_window then
      newest_window = newest_window + 1
      window_order = newest_window
    end
    table.sort(group.panes, function(a, b) return a.pane_order < b.pane_order end)
    for _, pane in ipairs(group.panes) do
      if not pane.data then
        local order = pane.pane_order
        if group.data then
          order = last_order[group.data.group] + 1
          last_order[group.data.group] = order
        end
        pane.data = {
          group = group.data and group.data.group or pane.window,
          title = group.data and group.data.title or pane.title,
          window_order = window_order,
          pane_order = order, active = not group.data and pane.active,
        }
        commands[#commands + 1] = M.write(pane)
      end
    end
    -- Keep the active pane in the original window, including its native window selection.
    if #group.panes > 1 then
      for _, pane in ipairs(group.panes) do
        if not pane.active then
          commands[#commands + 1] = { "break-pane", "-d", "-s", pane.id, "-n", pane.data.title }
        end
      end
    end
  end
  return commands
end

return M
