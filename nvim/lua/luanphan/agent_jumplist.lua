local M = {}

local entries = {}
local current = 0
local jumping = false

local function remove(index)
  table.remove(entries, index)
  if index <= current then current = current - 1 end
end

function M.record(bufnr)
  if jumping or entries[current] == bufnr then return end
  for index, entry in ipairs(entries) do
    if entry == bufnr then
      remove(index)
      break
    end
  end
  entries[#entries + 1] = bufnr
  if #entries > 100 then remove(1) end
  current = #entries
end

function M.offsets(live)
  local offsets = {}
  local position, origin = 0, 0
  for index, bufnr in ipairs(entries) do
    if live[bufnr] or index == current then position = position + 1 end
    if live[bufnr] then offsets[bufnr] = position end
    if index == current then origin = position end
  end
  for bufnr, position_in_history in pairs(offsets) do
    offsets[bufnr] = position_in_history - origin
  end
  return offsets
end

function M.jump(direction, count, available, activate)
  if jumping then return end
  for index = #entries, 1, -1 do
    if index ~= current and not available(entries[index]) then remove(index) end
  end

  local index = current + direction * count
  while entries[index] do
    local previous = current
    current = index
    jumping = true
    local ok, focused = pcall(activate, entries[index])
    jumping = false
    if ok and focused then return true end
    current = previous
    if not ok then error(focused) end
    remove(index)
    if direction < 0 then index = index - 1 end
  end
end

return M
