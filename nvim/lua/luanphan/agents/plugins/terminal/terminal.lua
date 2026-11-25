local M = {
  icon = "\u{f489}",
  plugin = "luanphan-panel-terminal",
  shell = true,
  restore_on_open = true,
  defaults = {
    cmd = function() return { vim.o.shell, "-i" } end,
  },
}

function M.new_session_id()
  local hex = vim.uv.random(16):gsub(".", function(byte)
    return string.format("%02x", byte:byte())
  end)
  return table.concat({ hex:sub(1, 8), hex:sub(9, 12), "4" .. hex:sub(14, 16),
    "8" .. hex:sub(18, 20), hex:sub(21, 32) }, "-")
end

function M.resume()
  return {}
end

function M.display_title()
  return ""
end

return M
