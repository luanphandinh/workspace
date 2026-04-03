-- Cursor CLI agent — thin wrapper over |terminal_agent.lua|.
-- Prerequisite: `agent` on PATH (https://cursor.com/docs/cli/overview).
-- Maps: <leader>cc toggle, <leader>cf focus, <leader>ca send selection.

return require("luanphan.terminal_agent").create({
  g_bufnr = "cursor_agent_bufnr",
  notify_prefix = "cursor_agent",
  augroup_prefix = "CursorAgent",
  hint_open = "<leader>cc",
  defaults = { cmd = "agent" },
  keymaps = {
    toggle = "<leader>cc",
    send = "<leader>cs",
    focus = "<leader>cf",
  },
  map_desc = {
    toggle = "Toggle Cursor agent terminal",
    send = "Send selection to Cursor agent",
    focus = "Focus Cursor agent terminal",
  },
})
