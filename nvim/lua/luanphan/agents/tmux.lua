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
  valid = function(data) return type(data.agent) == "string" end,
  on_attach = function(buf, pane)
    vim.b[buf].luanphan_agent_tmux_pane = pane.id
    vim.b[buf].luanphan_agent_name = pane.data.agent
    vim.b[buf].luanphan_agent_cwd = pane.data.cwd
  end,
  on_exit = function(buf, lost) vim.b[buf].luanphan_agent_backend_lost = lost end,
})

vim.luanphan_agent_tmux = backend.state

local list = backend.panes
function backend.panes(agent, cwd)
  return list(function(data) return (not agent or data.agent == agent) and (not cwd or data.cwd == cwd) end)
end

return backend
