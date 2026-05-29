local M = {}

local agent_order = { "cursor", "claude", "codex" }

local agent_defs = {
  cursor = {
    plugin = "luanphan-cursor-agent",
    g_bufnr = "cursor_agent_bufnr",
    notify_prefix = "cursor_agent",
    augroup_prefix = "CursorAgent",
    defaults = { cmd = "agent" },
    keys = {
      toggle = { lhs = "<leader>ac", mode = "n", desc = "Toggle Cursor agent terminal" },
      focus = { lhs = "<leader>af", mode = "n", desc = "Focus Cursor agent terminal" },
      send = { lhs = "<leader>as", mode = "x", desc = "Send selection to Cursor agent" },
    },
  },
  claude = {
    plugin = "luanphan-claude-agent",
    g_bufnr = "claude_agent_bufnr",
    notify_prefix = "claude_agent",
    augroup_prefix = "ClaudeAgent",
    defaults = { cmd = "claude" },
    keys = {
      toggle = { lhs = "<leader>xc", mode = "n", desc = "Toggle Claude Code terminal" },
      focus = { lhs = "<leader>xf", mode = "n", desc = "Focus Claude Code terminal" },
      send = { lhs = "<leader>xs", mode = "x", desc = "Send selection to Claude Code" },
    },
  },
  codex = {
    plugin = "luanphan-codex-agent",
    g_bufnr = "codex_agent_bufnr",
    notify_prefix = "codex_agent",
    augroup_prefix = "CodexAgent",
    defaults = function()
      local notify_cmd = vim.fn.expand("~/bin/codex-turn-ended-notify")
      local notify_arg = 'notify=["' .. notify_cmd:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"]'
      return { cmd = "codex", args = { "-c", notify_arg } }
    end,
    keys = {
      toggle = { lhs = "<leader>cc", mode = "n", desc = "Toggle Codex terminal" },
      focus = { lhs = "<leader>cf", mode = "n", desc = "Focus Codex terminal" },
      send = { lhs = "<leader>cs", mode = "x", desc = "Send selection to Codex" },
    },
  },
}

local apis = {}
local configured = {}
local setup_opts = {}

local function resolve_defaults(defaults)
  if type(defaults) == "function" then
    return defaults()
  end
  return defaults
end

local function get_agent(name)
  if apis[name] then
    return apis[name]
  end

  local def = agent_defs[name]
  apis[name] = require("luanphan.terminal_agent").create({
    g_bufnr = def.g_bufnr,
    notify_prefix = def.notify_prefix,
    augroup_prefix = def.augroup_prefix,
    hint_open = def.keys.toggle.lhs,
    defaults = resolve_defaults(def.defaults),
  })
  return apis[name]
end

local function setup_agent(name)
  local api = get_agent(name)
  if not configured[name] then
    api.setup(setup_opts[name])
    configured[name] = true
  end
  return api
end

function M.set_float_position(pos)
  for _, name in ipairs(agent_order) do
    setup_opts[name] = vim.tbl_extend("force", setup_opts[name] or {}, { float_position = pos })
    local api = apis[name]
    if api and type(api.set_float_position) == "function" then
      api.set_float_position(pos)
    end
  end
end

local function key_spec(name, action)
  local key = agent_defs[name].keys[action]
  local method = action == "send" and "send_selection" or action
  return {
    key.lhs,
    function()
      setup_agent(name)[method]()
    end,
    mode = key.mode,
    desc = key.desc,
  }
end

local function agent_spec(name)
  local def = agent_defs[name]
  return {
    def.plugin,
    virtual = true,
    keys = {
      key_spec(name, "toggle"),
      key_spec(name, "focus"),
      key_spec(name, "send"),
    },
    config = function()
      setup_agent(name)
    end,
  }
end

for _, name in ipairs(agent_order) do
  M[#M + 1] = agent_spec(name)
end

return M
