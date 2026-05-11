return require("luanphan.terminal_agent").create({
  g_bufnr = "codex_agent_bufnr",
  notify_prefix = "codex_agent",
  augroup_prefix = "CodexAgent",
  hint_open = "<leader>cc",
  defaults = { cmd = "codex" },
  keymaps = {
    toggle = "<leader>cc",
    send = "<leader>cs",
    focus = "<leader>cf",
  },
  map_desc = {
    toggle = "Toggle Codex terminal",
    send = "Send selection to Codex",
  },
})
