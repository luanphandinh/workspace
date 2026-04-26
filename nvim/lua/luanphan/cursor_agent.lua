return require("luanphan.terminal_agent").create({
  g_bufnr = "cursor_agent_bufnr",
  notify_prefix = "cursor_agent",
  augroup_prefix = "CursorAgent",
  hint_open = "<leader>cc",
  defaults = { cmd = "agent" },
  keymaps = {
    toggle = "<leader>ac",
    send = "<leader>as",
    focus = "<leader>af",
  },
  map_desc = {
    toggle = "Toggle Cursor agent terminal",
    send = "Send selection to Cursor agent",
    focus = "Focus Cursor agent terminal",
  },
})
