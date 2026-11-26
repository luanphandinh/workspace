-- Session ids saved by panels are version 4 UUIDs.
local M = {}

M.pattern = "^" .. string.rep("%x", 8) .. ("%-" .. string.rep("%x", 4)):rep(3) .. "%-" .. string.rep("%x", 12) .. "$"

function M.is_valid(id)
  return type(id) == "string" and id:match(M.pattern) ~= nil
end

function M.new()
  local hex = vim.uv.random(16):gsub(".", function(byte)
    return string.format("%02x", byte:byte())
  end)
  return table.concat({ hex:sub(1, 8), hex:sub(9, 12), "4" .. hex:sub(14, 16),
    "8" .. hex:sub(18, 20), hex:sub(21, 32) }, "-")
end

return M
