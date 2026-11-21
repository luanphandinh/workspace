local M = {
  icon = "\u{ec5c}",
  plugin = "luanphan-cursor-agent",
  g_bufnr = "cursor_agent_bufnr",
  notify_prefix = "cursor_agent",
  augroup_prefix = "CursorAgent",
  native_status = true,
  defaults = {
    cmd = {
      "sh", "-c", [[export NVIM_CURSOR_AGENT_TTY="$(tty)"; exec cursor-agent --plugin-dir "$0" "$@"]],
      vim.fn.stdpath("config") .. "/lua/luanphan/agents/plugins/cursor-hooks",
    },
    detach_on_quit = true,
  },
}

local title_status = {
  ["📤"] = "working", ["📂"] = "loading", ["🔄"] = "working",
  ["⌨️"] = "working", ["🧭"] = "working", ["⏳"] = "working",
  ["📋"] = "working", ["📝"] = "working",
  ["❓"] = "blocked", ["🔐"] = "blocked", ["✅"] = "idle",
}

function M.resume(id)
  return { "--resume", id }
end

function M.display_title(title)
  if type(title) ~= "string" then return title end
  local name, icon = title:match("^(.*) %- (%S+) ")
  local status = title_status[icon]
  if not status then return title end
  return name, status
end

function M.saved_title(bufnr)
  return require("luanphan.view_container").tab_label(bufnr, "cursor")
end

function M.decode_event(bufnr, event, emit)
  local id = event.sequence:match("^\27%]39001;cursor%-session=([%x-]+)$")
  if id then
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      emit({ thread_id = id, status = vim.b[bufnr].luanphan_agent_program_status or "idle" })
    end)
  elseif event.title then
    local buf = vim.b[bufnr]
    local name, status = M.display_title(event.title)
    local previous = buf.luanphan_agent_program_status
    if status == "idle" and (previous == "working" or previous == "blocked" or previous == "done") then
      status = "done"
    end
    emit({ status = status == "loading" and "idle" or status })
    if buf.luanphan_cursor_title == name then return end
    buf.luanphan_cursor_title = name
    vim.schedule(function() emit({ refresh_title = true, save_title = true }) end)
  end
end

return M
