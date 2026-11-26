local function command()
  return { vim.o.shell, "-i" }
end

local M = {
  icon = "\u{f489}",
  command = command,
  shell = true,
  restore_on_open = true,
  defaults = {
    cmd = command,
  },
}

M.new_session_id = require("luanphan.view_container.uuid").new

function M.resume()
  return {}
end

function M.display_title()
  return ""
end

return M
