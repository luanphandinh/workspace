local notify_cmd = vim.fn.expand("~/bin/codex-turn-ended-notify")
local notify_arg = 'notify=["' .. notify_cmd:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"]'

return require("luanphan.terminal_agent").create({
  g_bufnr = "codex_agent_bufnr",
  notify_prefix = "codex_agent",
  augroup_prefix = "CodexAgent",
  hint_open = "<leader>cc",
  defaults = { cmd = "codex", args = { "-c", notify_arg } },
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
