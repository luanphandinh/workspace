-- Terminal agents panel. The managed panel does the work; this file lists the agent providers
-- and the agent-only behavior: sending a selection to an agent.
local M = {}
local view_container = require("luanphan.view_container")
local selection = require("luanphan.agents.selection")

local agent_order = { "codex", "cursor", "claude", "terminal" }
local agent_key = "<leader>a"

local providers = { terminal = require("luanphan.view_container.shell") }
for _, name in ipairs(agent_order) do
  providers[name] = providers[name] or require("luanphan.agents.plugins." .. name .. "." .. name)
end

local function is_agent(name)
  return providers[name] ~= nil and not providers[name].shell
end

function M.toggle()
  require("luanphan.recent_paths").touch(vim.fn.getcwd())
  return view_container.toggle_panel(M, M.panel.reopen)
end

M.panel = require("luanphan.view_container.managed_panel").create(M, {
  backend = require("luanphan.agents.tmux"),
  providers = providers, kinds = agent_order, noun = "terminal agent", default_title = "Default Agent",
  session_dir = function(kind)
    return vim.g["luanphan_" .. kind .. "_sessions_dir"]
      or (vim.fn.stdpath("state") .. "/workspace-" .. kind .. "-sessions")
  end,
  default_kind_file = function()
    return vim.g.luanphan_default_agent_file or (vim.fn.stdpath("data") .. "/default-agent")
  end,
  default_kind = function() return M.default_agent() end,
  defaults = selection.defaults,
  extend_api = selection.attach,
  hint_open = agent_key, toggle = M.toggle,
  workspace = function(cwd) return require("luanphan.plugins.worktree").agent_workspace(cwd) end,
  group = "LuanphanAgentPanel", startup_group = "LuanphanAgentStartup", startup_flag = "luanphan_agent_startup_restored",
  view = {
    layout = function()
      return view_container.layout(require("luanphan.global_settings").read().agent_float,
        { border = "single", zindex = 45, min_height = 12 })
    end,
    bar = function() return require("luanphan.agents.window_bar").bar end,
    highlights = "NormalFloat:Normal,EndOfBuffer:,WinBar:Normal,WinBarNC:Normal,"
      .. "TabLineSel:Title,TabLine:LineNr,TabLineFill:Normal",
    editor = { key = function(cwd) return "agent:" .. cwd end },
    picker_title = "Terminal Agents",
    picker_opts = { layout_strategy = "center", layout_config = { width = 0.3, height = 0.25 } },
    empty_message = "no terminal agents registered",
    cycle_desc = "Next agent session",
  },
})

M.sessions = M.panel.sessions
M.instances = M.panel.instances
M.default_agent = M.panel.default_kind
M.set_default_agent = M.panel.set_default_kind
M.pick_default_agent = M.panel.pick_default_kind

function M.send_selection(name)
  local cwd, target = M.container:context(), nil
  if name then
    if not is_agent(name) then return false end
    target = M.container:recent_pane(cwd, name)
  else
    local visible = M.panel.visible()
    target = visible and is_agent(visible.kind) and visible.bufnr or M.container:recent_pane(cwd, nil, false, is_agent)
    name = target and vim.b[target].luanphan_view_kind or M.default_agent()
  end
  M.panel.provider(name).send_selection(target)
  return true
end

M.spec = M.panel.plugin_specs({
  { agent_key, M.toggle, mode = "n", desc = "Toggle agents" },
  { agent_key, function() M.send_selection() end, mode = { "x", "s" }, desc = "Send to active agent" },
  { "<leader>sad", M.pick_default_agent, desc = "Default agent" },
})

return M
