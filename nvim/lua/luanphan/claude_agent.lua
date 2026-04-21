return require("luanphan.terminal_agent").create({
  g_bufnr = "claude_agent_bufnr",
  notify_prefix = "claude_agent",
  augroup_prefix = "ClaudeAgent",
  hint_open = "<leader>ac",
  defaults = { cmd = "claude" },
  keymaps = {
    toggle = "<leader>cc",
    send = "<leader>cs",
    focus = "<leader>cf",
  },
  map_desc = {
    toggle = "Toggle Claude Code terminal",
    send = "Send selection to Claude Code",
  },
})
