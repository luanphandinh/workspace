return require("luanphan.terminal_agent").create({
  g_bufnr = "codex_agent_bufnr",
  notify_prefix = "codex_agent",
  augroup_prefix = "CodexAgent",
  hint_open = "<leader>xc",
  defaults = { cmd = "codex" },
  keymaps = {
    toggle = "<leader>xc",
    send = "<leader>xs",
    focus = "<leader>xf",
  },
  map_desc = {
    toggle = "Toggle Codex terminal",
    send = "Send selection to Codex",
  },
})
