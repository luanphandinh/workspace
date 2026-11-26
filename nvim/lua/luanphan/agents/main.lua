local M = {}
local terminal_agent = require("luanphan.agents.terminal-chat")
local backend = require("luanphan.agents.tmux")
local sessions = require("luanphan.agents.sessions")
local status = require("luanphan.agents.status")
local view_container = require("luanphan.view_container")
local pane_order = require("luanphan.view_container.pane_order")
local terminal = require("luanphan.view_container.terminal")

local agent_order = { "codex", "cursor", "claude", "terminal" }
local agent_key = "<leader>a"

local agent_defs = { terminal = require("luanphan.view_container.shell") }
for _, name in ipairs(agent_order) do
  local def = agent_defs[name] or require("luanphan.agents.plugins." .. name .. "." .. name)
  def.status = vim.tbl_extend("force", { decode = status.from_osc }, def.status or {})
  agent_defs[name] = def
end
sessions.setup(agent_defs, agent_order)

local apis = {}
local configured = {}
local agent_container
local setup_agent
local restored_cwds = {}

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

local function agent_buffer(name, cwd, prefer_visible)
  local selected = nil
  local selected_sequence = -1
  for _, pane in ipairs(backend.panes(name, cwd)) do
    local bufnr = pane.bufnr
    if prefer_visible and vim.fn.bufwinid(bufnr) ~= -1 then return bufnr end
    local sequence = tonumber(vim.b[bufnr].luanphan_agent_last_used) or 0
    if sequence > selected_sequence then
      selected = bufnr
      selected_sequence = sequence
    end
  end
  return selected
end

local function open_tabs(cwd, closing_bufnr)
  local tabs = sessions.live(cwd, closing_bufnr)
  if agent_container.display_style == "tile" then
    table.sort(tabs, function(a, b) return a.bufnr < b.bufnr end)
  end
  pane_order.sort(tabs)
  return tabs
end

local function most_recent_tab(cwd, agents_only)
  local selected = nil
  local selected_sequence = -1
  for _, tab in ipairs(open_tabs(cwd)) do
    if (not agents_only or is_agent(tab.agent)) and tab.last_used > selected_sequence then
      selected = tab
      selected_sequence = tab.last_used
    end
  end
  return selected
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

local function visible_agent()
  local win = agent_container:content_window()
  if not win then return end
  local bufnr = vim.api.nvim_win_get_buf(win)
  local name = vim.b[bufnr].luanphan_agent_name
  if agent_defs[name] then return { name = name, bufnr = bufnr } end
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
    pane_order = pane_order.get(session),
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

local function restore_panel_sessions(cwd)
  if restored_cwds[cwd] then return end
  restored_cwds[cwd] = true
  local path = vim.uv.fs_realpath(cwd) or cwd
  for _, name in ipairs(agent_order) do
    if agent_defs[name].restore_on_open then
      local live = {}
      for _, pane in ipairs(backend.panes(name, cwd)) do
        local id = vim.b[pane.bufnr].luanphan_agent_thread_id
        if id then live[id] = true end
      end
      local saved_sessions = sessions.list(name)
      table.sort(saved_sessions, function(a, b)
        if a.last_used ~= b.last_used then return a.last_used < b.last_used end
        return a.thread_id < b.thread_id
      end)
      for _, session in ipairs(saved_sessions) do
        if session.path == path and not live[session.thread_id] then
          setup_agent(name).start_hidden(cwd, resume_options(session))
        end
      end
    end
  end
end

local function get_agent(name)
  if apis[name] then
    return apis[name]
  end

  local def = agent_defs[name]
  apis[name] = terminal_agent.create({
    name = name,
    shell = def.shell,
    status = def.status,
    new_session_id = def.new_session_id,
    hint_open = agent_key,
    defaults = def.defaults,
    panel = M,
    container = agent_container,
    current = function() return agent_buffer(name, vim.fn.getcwd(), true) end,
    on_register = M.map_create_shortcuts,
    on_show = function(bufnr, cwd)
      backend.focus(bufnr)
      local seconds, microseconds = vim.uv.gettimeofday()
      vim.b[bufnr].luanphan_agent_saved_use = seconds + microseconds / 1000000
      remember_pane(bufnr)
      restore_panel_sessions(cwd)
    end,
    on_close = function(bufnr, cwd)
      local id = sessions.supported(name) and vim.b[bufnr].luanphan_agent_thread_id
      local lost = vim.b[bufnr].luanphan_agent_backend_lost
      if lost then restored_cwds[cwd] = nil end
      return function()
        if id and not lost and type(vim.v.exiting) ~= "number" then
          sessions.forget_buffer(bufnr, name, id)
        end
      end
    end,
  })
  return apis[name]
end

setup_agent = function(name)
  local api = get_agent(name)
  if not configured[name] then
    api.setup()
    configured[name] = true
  end
  return api
end

function M.restore_running()
  local running = {}
  backend.restore(function(record)
    local data = record.data
    if agent_defs[data.agent] and vim.fn.isdirectory(data.cwd) == 1 then
      running[#running + 1] = record
    end
  end)
  if #running == 0 then return end
  local saved = {}
  for _, session in ipairs(sessions.list()) do
    saved[sessions.key(session)] = session
  end
  for _, record in ipairs(running) do
    local data = record.data
    local session = data.thread_id and saved[sessions.key(data)]
    data.used_at = math.max(data.used_at or 0, session and session.last_used or 0)
    record.pane_order = record.pane_order or (session and pane_order.get(session))
  end
  table.sort(running, function(a, b)
    if a.data.used_at ~= b.data.used_at then return a.data.used_at < b.data.used_at end
    return (a.data.used or 0) < (b.data.used or 0)
  end)
  for _, record in ipairs(running) do
    local data = record.data
    if data.used_at > 0 or (data.used or 0) > 0 then
      data.used = (vim.g.luanphan_agent_use_sequence or 0) + 1
      vim.g.luanphan_agent_use_sequence = data.used
    end
    local buf = setup_agent(data.agent).adopt(record)
    if buf then
      local session = data.thread_id and saved[sessions.key(data)]
      vim.b[buf].luanphan_agent_saved_label = session and session.agent_label or M.display_title(data.agent, data.label)
    end
  end
end

function M.focus(name, bufnr, opts)
  M.restore_running()
  if not agent_defs[name] then
    return false
  end
  return setup_agent(name).focus(bufnr or agent_buffer(name, vim.fn.getcwd()), opts, true)
end

local function new_tile(name, opts)
  return agent_container:open_tile(vim.fn.getcwd(), function(place)
    return setup_agent(name).new(opts, place and function(bufnr)
      agent_container:save_pane_order(place({ bufnr = bufnr }))
    end)
  end, opts and opts.thread_id)
end

function M.open(name, bufnr, opts)
  M.restore_running()
  if not agent_defs[name] then
    return false
  end
  local target = bufnr or agent_buffer(name, vim.fn.getcwd())
  if not target then return new_tile(name, opts) end
  return setup_agent(name).focus(target, opts)
end

function M.new(name, opts)
  M.restore_running()
  if not agent_defs[name] then
    return false
  end
  return new_tile(name, opts)
end

function M.resume(session, opts)
  if not sessions.supported(session.agent) or not sessions.valid_id(session.thread_id) then return false end
  M.restore_running()
  for _, pane in ipairs(backend.panes(session.agent, session.path)) do
    if vim.b[pane.bufnr].luanphan_agent_thread_id == session.thread_id then
      return M.open(session.agent, pane.bufnr, opts)
    end
  end
  return M.new(session.agent, vim.tbl_extend("force", opts or {}, resume_options(session)))
end

local function reopen(startup)
  M.restore_running()
  if startup and visible_agent() then return end
  local cwd = vim.fn.getcwd()
  local opts = startup and { view_mode = true } or nil
  local active = most_recent_tab(cwd)
  if active then return M.open(active.agent, active.bufnr, opts) end
  local saved = sessions.latest(cwd)
  if saved then return M.resume(saved, opts) end
  if not startup then return M.open(M.default_agent()) end
end

function M.toggle()
  require("luanphan.recent_paths").touch(vim.fn.getcwd())
  return view_container.toggle_panel(M, reopen)
end

local function restore_on_first_ui()
  if vim.g.luanphan_agent_startup_restored or vim.v.vim_did_enter == 0 or #vim.api.nvim_list_uis() == 0 then return end
  vim.g.luanphan_agent_startup_restored = true
  reopen(true)
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
  local visible = visible_agent()
  local active = most_recent_tab(vim.fn.getcwd(), true)
  name = name or (visible and is_agent(visible.name) and visible.name) or (active and active.agent) or M.default_agent()
  if not is_agent(name) then
    return false
  end
  local target = agent_buffer(name, vim.fn.getcwd())
  setup_agent(name).send_selection(target)
  return true
end

agent_container = view_container.create({
  context = vim.fn.getcwd,
  tabs = open_tabs,
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
  reorder = function(tabs)
    agent_container:save_pane_order(tabs)
    agent_container:refresh()
  end,
  choices = agent_choices,
  activate = function(tab, opts)
    return M.open(tab.agent, tab.bufnr, opts)
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
M.container = agent_container
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
      vim.api.nvim_create_autocmd({ "VimEnter", "UIEnter" }, {
        group = group,
        callback = function() vim.schedule(restore_on_first_ui) end,
      })
      vim.api.nvim_create_autocmd("TermRequest", { group = group, callback = receive_terminal_event })
      view_container.track_directory(group, function(cwd)
        local pane = visible_agent()
        if pane and vim.b[pane.bufnr].luanphan_agent_cwd == cwd then return pane end
      end, function()
        agent_container:hide()
      end, function(cwd, pane)
        if visible_agent() then return end
        local buf = terminal_agent.running(pane.bufnr) and pane.bufnr or agent_buffer(pane.name, cwd)
        if buf then M.open(pane.name, buf) end
      end)
    end or nil,
    config = function()
      setup_agent(name)
    end,
  }
end

M.spec = vim.iter(agent_order):filter(function(name) return agent_defs[name].plugin ~= nil end):map(agent_spec):totable()

return M
