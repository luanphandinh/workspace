return require("luanphan.terminal_agent").create({
  g_bufnr = "claude_agent_bufnr",
  notify_prefix = "claude_agent",
  augroup_prefix = "ClaudeAgent",
  hint_open = "<leader>xc",
  defaults = { cmd = "claude" },
  keymaps = {
    toggle = "<leader>xc",
    send = "<leader>xs",
    focus = "<leader>xf",
  },
  map_desc = {
    toggle = "Toggle Claude Code terminal",
    send = "Send selection to Claude Code",
  },
})
