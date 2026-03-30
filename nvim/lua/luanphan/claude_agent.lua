-- Claude Code CLI — thin wrapper over |terminal_agent.lua|.
-- Prerequisite: `claude` on PATH.
-- Maps: <leader>ac toggle, <leader>as send selection.

return require("luanphan.terminal_agent").create({
  g_bufnr = "claude_agent_bufnr",
  notify_prefix = "claude_agent",
  augroup_prefix = "ClaudeAgent",
  hint_open = "<leader>ac",
  defaults = { cmd = "claude" },
  keymaps = {
    toggle = "<leader>ac",
    send = "<leader>as",
    focus = "<leader>af",
  },
  map_desc = {
    toggle = "Toggle Claude Code terminal",
    send = "Send selection to Claude Code",
  },
})
