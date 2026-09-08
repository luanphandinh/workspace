local M = {}

local agent_order = { "cursor", "claude", "codex" }

local agent_defs = {
  cursor = {
    plugin = "luanphan-cursor-agent",
    g_bufnr = "cursor_agent_bufnr",
    notify_prefix = "cursor_agent",
    augroup_prefix = "CursorAgent",
    defaults = { cmd = "cursor-agent" },
    keys = {
      toggle = { lhs = "<leader>ac", mode = "n", desc = "Toggle terminal" },
      focus = { lhs = "<leader>af", mode = "n", desc = "Focus terminal" },
      send = { lhs = "<leader>as", mode = "x", desc = "Send selection" },
    },
  },
  claude = {
    plugin = "luanphan-claude-agent",
    g_bufnr = "claude_agent_bufnr",
    notify_prefix = "claude_agent",
    augroup_prefix = "ClaudeAgent",
    defaults = { cmd = "claude" },
    keys = {
      toggle = { lhs = "<leader>xc", mode = "n", desc = "Toggle terminal" },
      focus = { lhs = "<leader>xf", mode = "n", desc = "Focus terminal" },
      send = { lhs = "<leader>xs", mode = "x", desc = "Send selection" },
    },
  },
  codex = {
    plugin = "luanphan-codex-agent",
    g_bufnr = "codex_agent_bufnr",
    notify_prefix = "codex_agent",
    augroup_prefix = "CodexAgent",
    defaults = { cmd = "mcodex", detach_on_quit = true },
    keys = {
      toggle = { lhs = "<leader>;", mode = "n", desc = "Toggle agents" },
      focus = { lhs = "<leader>cf", mode = "n", desc = "Focus terminal" },
      send = { lhs = "<leader>;", mode = { "x", "s" }, desc = "Send to active agent" },
    },
  },
}

local apis = {}
local configured = {}
local setup_opts = {}
local agent_container

local function terminal_running(bufnr)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if vim.bo[bufnr].buftype ~= "terminal" then
    return false
  end
  local job = vim.b[bufnr].terminal_job_id
  if type(job) ~= "number" or job <= 0 then
    return false
  end
  local ok, status = pcall(vim.fn.jobwait, { job }, 0)
  return ok and status[1] == -1
end

local function normalize_bufnrs(value)
  if type(value) == "number" then
    return { value }
  end
  return type(value) == "table" and value or {}
end

local function agent_buffers(name, cwd)
  local def = agent_defs[name]
  local buffers = def and vim.g[def.g_bufnr] or nil
  local result = {}
  local stored = type(buffers) == "table" and buffers[cwd] or nil
  for _, bufnr in ipairs(normalize_bufnrs(stored)) do
    if terminal_running(bufnr) then
      result[#result + 1] = bufnr
    end
  end
  return result
end

local function agent_buffer(name, cwd)
  local selected = nil
  local selected_sequence = -1
  for _, bufnr in ipairs(agent_buffers(name, cwd)) do
    local sequence = tonumber(vim.b[bufnr].luanphan_agent_last_used) or 0
    if sequence > selected_sequence then
      selected = bufnr
      selected_sequence = sequence
    end
  end
  return selected
end

local function open_tabs(cwd)
  local tabs = {}
  for _, name in ipairs(agent_order) do
    local bufnrs = agent_buffers(name, cwd)
    for index, bufnr in ipairs(bufnrs) do
      tabs[#tabs + 1] = {
        id = name .. ":" .. bufnr,
        label = #bufnrs > 1 and (name .. " " .. index) or name,
        agent = name,
        bufnr = bufnr,
      }
    end
  end
  return tabs
end

local function most_recent_tab(cwd)
  local selected = nil
  local selected_sequence = -1
  for _, tab in ipairs(open_tabs(cwd)) do
    local sequence = tonumber(vim.b[tab.bufnr].luanphan_agent_last_used) or 0
    if sequence > selected_sequence then
      selected = tab
      selected_sequence = sequence
    end
  end
  return selected
end

local function agent_choices()
  local choices = {}
  for _, name in ipairs(agent_order) do
    choices[#choices + 1] = {
      id = name,
      label = name,
      display = name,
      ordinal = name,
    }
  end
  return choices
end

local function visible_agent()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local bufnr = vim.api.nvim_win_get_buf(win)
      local name = vim.b[bufnr].luanphan_agent_name
      if agent_defs[name] and vim.b[bufnr].luanphan_persist_term then
        return { name = name, bufnr = bufnr, win = win }
      end
    end
  end
  return nil
end

local function close_visible_agents(except_bufnr)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local bufnr = vim.api.nvim_win_get_buf(win)
      local name = vim.b[bufnr].luanphan_agent_name
      if bufnr ~= except_bufnr and agent_defs[name] and vim.b[bufnr].luanphan_persist_term then
        pcall(vim.api.nvim_win_close, win, false)
      end
    end
  end
end

function M.agent_buffer_keys()
  local keys = {}
  for _, name in ipairs(agent_order) do
    keys[#keys + 1] = { name = name, key = agent_defs[name].g_bufnr }
  end
  return keys
end

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
    status_name = name,
    g_bufnr = def.g_bufnr,
    notify_prefix = def.notify_prefix,
    augroup_prefix = def.augroup_prefix,
    hint_open = def.keys.toggle.lhs,
    defaults = resolve_defaults(def.defaults),
    on_prepare = function(win)
      agent_container:reserve(win)
    end,
    on_show = function(bufnr, win, cwd)
      agent_container:attach(win, bufnr, name .. ":" .. bufnr, cwd)
    end,
    on_close = function(bufnr, cwd)
      agent_container:forget(name .. ":" .. bufnr, bufnr, cwd)
    end,
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

function M.focus(name, bufnr, opts)
  if not agent_defs[name] then
    return false
  end
  local target = bufnr or agent_buffer(name, vim.fn.getcwd())
  if not target then
    return setup_agent(name).focus(bufnr, opts)
  end
  close_visible_agents(target)
  return setup_agent(name).focus(target, opts)
end

function M.open(name, bufnr, opts)
  if not agent_defs[name] then
    return false
  end
  local target = bufnr or agent_buffer(name, vim.fn.getcwd())
  local visible = visible_agent()
  if visible and visible.bufnr ~= target then
    setup_agent(visible.name).save_view(visible.win)
    close_visible_agents(visible.bufnr)
    opts = vim.tbl_extend("force", opts or {}, { reuse_win = visible.win })
  else
    close_visible_agents(target)
  end
  if target then
    return setup_agent(name).focus(target, opts)
  end
  return setup_agent(name).new(opts)
end

function M.new(name)
  if not agent_defs[name] then
    return false
  end
  local visible = visible_agent()
  local opts
  if visible then
    setup_agent(visible.name).save_view(visible.win)
    close_visible_agents(visible.bufnr)
    opts = { reuse_win = visible.win }
  end
  return setup_agent(name).new(opts)
end

function M.toggle_agent(name)
  if not agent_defs[name] then
    return false
  end
  local target = agent_buffer(name, vim.fn.getcwd())
  local visible = visible_agent()
  if target and visible and visible.bufnr == target then
    setup_agent(name).toggle()
    return true
  end
  return M.open(name, target)
end

function M.toggle()
  if visible_agent() then
    close_visible_agents()
    return
  end
  local active = most_recent_tab(vim.fn.getcwd())
  M.open(active and active.agent or "codex", active and active.bufnr or nil)
end

function M.send_selection(name)
  local visible = visible_agent()
  local active = most_recent_tab(vim.fn.getcwd())
  name = name or (visible and visible.name) or (active and active.agent) or "codex"
  if not agent_defs[name] then
    return false
  end
  local target = agent_buffer(name, vim.fn.getcwd())
  local visible = visible_agent()
  local opts
  if visible and visible.bufnr ~= target then
    setup_agent(visible.name).save_view(visible.win)
    close_visible_agents(visible.bufnr)
    opts = { reuse_win = visible.win }
  else
    close_visible_agents(target)
  end
  setup_agent(name).send_selection(target, opts)
  return true
end

local function key_spec(name, action)
  local key = agent_defs[name].keys[action]
  return {
    key.lhs,
    function()
      if name == "codex" and action == "toggle" then
        M.toggle()
      elseif name == "codex" and action == "send" then
        M.send_selection()
      elseif action == "toggle" then
        M.toggle_agent(name)
      elseif action == "focus" then
        M.focus(name)
      else
        M.send_selection(name)
      end
    end,
    mode = key.mode,
    desc = key.desc,
  }
end

agent_container = require("luanphan.view_container").create({
  context = vim.fn.getcwd,
  tabs = open_tabs,
  choices = agent_choices,
  activate = function(tab, opts)
    M.open(tab.agent, tab.bufnr, opts)
  end,
  create = function(choice)
    M.new(choice.id)
  end,
  picker_title = "Terminal Agents",
  empty_message = "no terminal agents registered",
  cycle_desc = "Next terminal agent",
  new_desc = "New terminal agent",
})

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
