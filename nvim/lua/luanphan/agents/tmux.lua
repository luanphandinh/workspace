local backend = require("luanphan.view_container.tmux.managed").create({
  server = function()
    return {
      name = "luanphan-agents",
      socket = vim.g.luanphan_agent_tmux_socket or vim.env.LUANPHAN_AGENT_TMUX_SOCKET,
      config = "/dev/null",
    }
  end,
  state = vim.luanphan_agent_tmux,
  augroup = "LuanphanAgentTmux",
  metadata = "@luanphan-agent",
  replay_osc = true,
})

vim.luanphan_agent_tmux = backend.state

return backend
