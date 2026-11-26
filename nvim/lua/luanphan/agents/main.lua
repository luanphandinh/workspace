local M = {}
local terminal_agent = require("luanphan.agents.terminal-chat")
local backend = require("luanphan.agents.tmux")
local sessions = require("luanphan.agents.sessions")
local status = require("luanphan.agents.status")
local view_container = require("luanphan.view_container")
local terminal = require("luanphan.view_container.terminal")

local agent_order = { "codex", "cursor", "claude", "terminal" }
local agent_key = "<leader>a"

local agent_defs = { terminal = require("luanphan.view_container.shell") }
for _, name in ipairs(agent_order) do
  local def = agent_defs[name] or require("luanphan.agents.plugins." .. name .. "." .. name)
  def.status = vim.tbl_extend("force", { decode = status.from_osc }, def.status or {})
  agent_defs[name] = def
end

local lifecycle
local agent_container

local function is_agent(name)
  return agent_defs[name] and not agent_defs[name].shell
end

local function default_agent_file()
  return vim.g.luanphan_default_agent_file or (vim.fn.stdpath("data") .. "/default-agent")
end

function M.default_agent()
  local ok, lines = pcall(vim.fn.readfile, default_agent_file(), "", 1)
  local name = ok and vim.trim(lines[1] or "") or ""
  return is_agent(name) and name or agent_order[1]
end

function M.set_default_agent(name)
  if not is_agent(name) then
    return false
  end
  local path = default_agent_file()
  local ok = pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ":h"), "p")
  local wrote, result = pcall(vim.fn.writefile, { name }, path)
  if not ok or not wrote or result ~= 0 then
    vim.notify("Could not save default agent", vim.log.levels.ERROR)
    return false
  end
  vim.notify("Default agent: " .. name)
  return true
end

local function agent_choices()
  local choices = {}
  for _, name in ipairs(agent_order) do
    if is_agent(name) then
      choices[#choices + 1] = { id = name, label = name, display = name, ordinal = name }
    end
  end
  return choices
end

function M.pick_default_agent()
  local current = M.default_agent()
  local choices = agent_choices()
  for _, choice in ipairs(choices) do
    if choice.id == current then
      choice.display = choice.label .. " (current)"
    end
  end
  view_container.select("Default Agent", choices, function(choice)
    M.set_default_agent(choice.id)
  end, {
    layout_strategy = "center",
    layout_config = { width = 0.3, height = 0.25 },
  })
end

function M.agent_icon(name)
  return agent_defs[name].icon
end

function M.display_title(name, title)
  local def = agent_defs[name]
  if def and def.display_title then return def.display_title(title) end
  return title
end

function M.map_create_shortcuts(bufnr)
  local opts = { buffer = bufnr, silent = true, nowait = true }
  -- Keep the editor's New buffer mapping from replacing a panel buffer.
  vim.keymap.set("n", "<leader>fn", "<Nop>", opts)
  vim.keymap.set("n", "<leader>nt", function() M.new("terminal") end,
    vim.tbl_extend("force", opts, { desc = "New terminal" }))
  vim.keymap.set("n", "<leader>na", function() M.new(M.default_agent()) end,
    vim.tbl_extend("force", opts, { desc = "New default terminal agent" }))
  vim.keymap.set("n", "<leader>nA", function() agent_container:pick() end,
    vim.tbl_extend("force", opts, { desc = "Select terminal agent" }))
  if not vim.b[bufnr].luanphan_agent_new_menu then
    local ok, which_key = pcall(require, "which-key")
    if ok then
      which_key.add({ { "<leader>n", group = "New", buffer = bufnr } })
      vim.b[bufnr].luanphan_agent_new_menu = true
    end
  end
end

local function resume_options(session)
  local provider = agent_defs[session.agent]
  return {
    args = provider.resume(session.thread_id),
    thread_id = session.thread_id,
    agent_label = not provider.restore_on_open and session.agent_label or nil,
    saved_pane = session,
  }
end

local function remember_pane(bufnr)
  local buf = vim.b[bufnr]
  local name = buf.luanphan_agent_name
  backend.update(bufnr, {
    thread_id = buf.luanphan_agent_thread_id,
    title = buf.term_title,
    label = view_container.tab_label(bufnr, name),
    status = buf.luanphan_agent_program_status,
    used = buf.luanphan_agent_last_used,
    used_at = buf.luanphan_agent_saved_use,
  })
end

local function create_agent(name)
  local def = agent_defs[name]
  return terminal_agent.create({
    name = name, shell = def.shell, status = def.status, defaults = def.defaults,
    new_session_id = def.new_session_id, hint_open = agent_key,
    panel = M, container = agent_container,
    current = function() return agent_container:recent_pane(vim.fn.getcwd(), name, true) end,
    on_register = M.map_create_shortcuts,
    on_show = lifecycle.show,
    mark_used = lifecycle.mark_used,
    on_close = lifecycle.close,
  })
end

function M.resume(session, opts)
  if not sessions.supported(session.agent) or not sessions.valid_id(session.thread_id) then return false end
  return lifecycle.resume(session, opts)
end

function M.toggle()
  require("luanphan.recent_paths").touch(vim.fn.getcwd())
  return view_container.toggle_panel(M, lifecycle.reopen)
end

local function receive_terminal_event(args)
  local bufnr = args.buf
  local name = vim.b[bufnr].luanphan_agent_name
  local def = agent_defs[name]
  local sequence = args.data and args.data.sequence
  if not name or not sequence then return end
  local status_options = def and def.status
  local osc_status = status_options and status_options.decode and status_options.decode(sequence)
  if osc_status then
    status.update(bufnr, osc_status)
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then remember_pane(bufnr) end
    end)
  end
  local title = terminal.request_title(sequence)
  -- Decoders defer persistence and redraws until the terminal callback has returned.
  local function emit(event)
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.b[bufnr].luanphan_agent_name ~= name then return end
    status.update(bufnr, event.status)
    local changed_id = sessions.update(bufnr, event)
    remember_pane(bufnr)
    local bar = agent_container.opts.bar()
    if changed_id then
      bar:refresh(true)
    elseif event.refresh_title then
      bar:update_title(bufnr, view_container.tab_label(bufnr))
    end
  end
  if def and def.decode_event then
    def.decode_event(bufnr, { sequence = sequence, title = title, status = osc_status }, emit)
  elseif title then
    vim.schedule(function() emit({ refresh_title = true }) end)
  end
end

function M.hide(except)
  if except and agent_container:visible_window(agent_container.layout_context, except) then return false end
  return agent_container:hide()
end

function M.send_selection(name)
  if not name then
    local visible = lifecycle.visible()
    local active = visible and is_agent(visible.kind) and visible or lifecycle.recent_tab(vim.fn.getcwd(), is_agent)
    name = active and active.kind or M.default_agent()
  end
  if not is_agent(name) then
    return false
  end
  local target = agent_container:recent_pane(vim.fn.getcwd(), name)
  lifecycle.provider(name).send_selection(target)
  return true
end

agent_container = view_container.create({
  context = vim.fn.getcwd,
  panes = {
    backend = backend,
    kinds = agent_order,
    kind = function(buf) return vim.b[buf].luanphan_agent_name end,
    last_used = function(buf) return tonumber(vim.b[buf].luanphan_agent_last_used) or 0 end,
  },
  layout = function()
    return view_container.layout(require("luanphan.global_settings").read().agent_float,
      { border = "single", zindex = 45, min_height = 12 })
  end,
  bar = function() return require("luanphan.agents.window_bar").bar end,
  highlights = "NormalFloat:Normal,EndOfBuffer:,WinBar:Normal,WinBarNC:Normal,"
    .. "TabLineSel:Title,TabLine:LineNr,TabLineFill:Normal",
  editor = { key = function(cwd) return "agent:" .. cwd end },
  title = function(buf, title)
    local buffer = vim.b[buf]
    title = M.display_title(buffer.luanphan_agent_name, title)
    if type(title) ~= "string" or title == "" or title == vim.api.nvim_buf_get_name(buf) then
      return buffer.luanphan_agent_saved_label
    end
    return title
  end,
  snapshot = sessions.snapshot,
  choices = agent_choices,
  activate = function(tab, opts)
    return M.open(tab.kind, tab.bufnr, opts)
  end,
  create = function(choice)
    M.new(choice.id)
  end,
  create_key = false,
  picker_title = "Terminal Agents",
  picker_opts = {
    layout_strategy = "center",
    layout_config = { width = 0.3, height = 0.25 },
  },
  empty_message = "no terminal agents registered",
  cycle_desc = "Next agent session",
})
lifecycle = require("luanphan.view_container.managed_panel").create(agent_container, {
  owner = M, providers = agent_defs, create = create_agent, remember = remember_pane,
  latest = sessions.latest, default_kind = M.default_agent,
  list = sessions.list, key = sessions.key, resume_options = resume_options,
  fields = {
    kind = "agent", id = "thread_id", buffer_id = "luanphan_agent_thread_id",
    used = "luanphan_agent_last_used", used_at = "luanphan_agent_saved_use",
    sequence = "luanphan_agent_use_sequence", lost = "luanphan_agent_backend_lost",
  },
  discard = function(buf)
    local name, id = vim.b[buf].luanphan_agent_name, vim.b[buf].luanphan_agent_thread_id
    if sessions.supported(name) and id then return function() sessions.forget_buffer(buf, name, id) end end
  end,
  adopted = function(buf, data, saved)
    vim.b[buf].luanphan_agent_saved_label = saved and saved.agent_label or M.display_title(data.agent, data.label)
  end,
})
M.restore_running, M.new, M.open, M.focus = lifecycle.restore_running, lifecycle.new, lifecycle.open, lifecycle.focus
M.container = agent_container
sessions.setup(agent_defs, agent_order, agent_container)
agent_container:watch(vim.api.nvim_create_augroup("LuanphanAgentPanel", { clear = true }))

local function agent_spec(name)
  local def = agent_defs[name]
  local keys = {}
  local primary = name == agent_order[1]
  if primary then
    keys[#keys + 1] = {
      agent_key,
      function()
        require("luanphan.agents.main").toggle()
      end,
      mode = "n",
      desc = "Toggle agents",
    }
    keys[#keys + 1] = {
      agent_key,
      function()
        require("luanphan.agents.main").send_selection()
      end,
      mode = { "x", "s" },
      desc = "Send to active agent",
    }
    keys[#keys + 1] = {
      "<leader>sad",
      function()
        require("luanphan.agents.main").pick_default_agent()
      end,
      desc = "Default agent",
    }
  end
  return {
    def.plugin,
    virtual = true,
    keys = keys,
    init = primary and function()
      local group = vim.api.nvim_create_augroup("LuanphanAgentStartup", { clear = true })
      lifecycle.watch(group, "luanphan_agent_startup_restored")
      vim.api.nvim_create_autocmd("TermRequest", { group = group, callback = receive_terminal_event })
    end or nil,
    config = function()
      lifecycle.provider(name)
    end,
  }
end

M.spec = vim.iter(agent_order):filter(function(name) return agent_defs[name].plugin ~= nil end):map(agent_spec):totable()

return M
