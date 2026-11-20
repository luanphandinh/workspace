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

function M.jump(direction, count, available, activate)
  if jumping then return end
  for index = #entries, 1, -1 do
    if index ~= current and not available(entries[index]) then remove(index) end
  end

  local index = current + direction * count
  while entries[index] do
    jumping = true
    local ok, focused = pcall(activate, entries[index])
    jumping = false
    if not ok then error(focused) end
    if focused then
      current = index
      return
    end
    remove(index)
    if direction < 0 then index = index - 1 end
  end
end

return M
