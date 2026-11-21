local M = {}
local jumplist = require("luanphan.agents.jumplist")
local terminal_agent = require("luanphan.agents.terminal-chat")
local sessions = require("luanphan.agents.sessions")
local status = require("luanphan.agents.status")

local agent_order = { "codex", "cursor", "claude" }
local agent_key = "<leader>a"

local agent_defs = {}
for _, name in ipairs(agent_order) do
  agent_defs[name] = require("luanphan.agents.plugins." .. name .. "." .. name)
end
sessions.setup(agent_defs, agent_order)

local apis = {}
local configured = {}
local agent_container
local setup_agent

local function default_agent_file()
  return vim.g.luanphan_default_agent_file or (vim.fn.stdpath("data") .. "/default-agent")
end

function M.default_agent()
  local ok, lines = pcall(vim.fn.readfile, default_agent_file(), "", 1)
  local name = ok and vim.trim(lines[1] or "") or ""
  return agent_defs[name] and name or agent_order[1]
end

function M.set_default_agent(name)
  if not agent_defs[name] then
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

local function jump_available(bufnr)
  if not terminal_agent.running(bufnr) then return false end
  local cwd = vim.b[bufnr].luanphan_agent_cwd
  return type(cwd) == "string" and vim.fn.isdirectory(cwd) == 1
end

local function jump_session(direction, count)
  return jumplist.jump(direction, count or vim.v.count1, jump_available, function(bufnr)
    local buf = vim.b[bufnr]
    return require("luanphan.agents.sidebar").select_session({
      agent = buf.luanphan_agent_name,
      bufnr = bufnr,
      path = buf.luanphan_agent_cwd,
    }, { view_mode = true })
  end)
end

function M.map_jump_keys(bufnr, keep_focus)
  for _, binding in ipairs({
    { "<C-o>", -1, "Older agent session" },
    { "<C-i>", 1, "Newer agent session" },
  }) do
    local key, direction, description = unpack(binding)
    vim.keymap.set("n", key, function()
      local win = keep_focus and vim.api.nvim_get_current_win()
      if jump_session(direction) and win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
      end
    end, { buffer = bufnr, silent = true, desc = description })
  end
end

local function agent_buffers(name, cwd, closing_bufnr)
  local def = agent_defs[name]
  local buffers = def and vim.g[def.g_bufnr] or nil
  local result = {}
  local stored = type(buffers) == "table" and buffers[cwd] or nil
  for _, bufnr in ipairs(type(stored) == "table" and stored or {}) do
    if bufnr == closing_bufnr or terminal_agent.running(bufnr) then
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

local function open_tabs(cwd, closing_bufnr)
  local tabs = {}
  for _, name in ipairs(agent_order) do
    local bufnrs = agent_buffers(name, cwd, closing_bufnr)
    for index, bufnr in ipairs(bufnrs) do
      tabs[#tabs + 1] = {
        id = name .. ":" .. bufnr,
        label = #bufnrs > 1 and (name .. " " .. index) or name,
        agent = name,
        bufnr = bufnr,
      }
    end
  end
  if agent_container.display_style == "tile" then
    table.sort(tabs, function(a, b) return a.bufnr < b.bufnr end)
  end
  sessions.sort_by_order(tabs)
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

function M.pick_default_agent()
  local current = M.default_agent()
  local choices = agent_choices()
  for _, choice in ipairs(choices) do
    if choice.id == current then
      choice.display = choice.label .. " (current)"
    end
  end
  require("luanphan.view_container").select("Default Agent", choices, function(choice)
    M.set_default_agent(choice.id)
  end, {
    layout_strategy = "center",
    layout_config = { width = 0.3, height = 0.25 },
  })
end

local function visible_agent()
  local current = vim.api.nvim_get_current_win()
  local selected = vim.api.nvim_win_get_buf(current)
  local name = vim.b[selected].luanphan_agent_name
  if agent_defs[name] and vim.w[current].luanphan_view_anchor then
    return { name = name, bufnr = selected, win = current }
  end
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
  local keep_win = except_bufnr and vim.fn.bufwinid(except_bufnr) or -1
  local keep_group = keep_win ~= -1 and vim.w[keep_win].luanphan_view_anchor
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local bufnr = vim.api.nvim_win_get_buf(win)
      local name = vim.b[bufnr].luanphan_agent_name
      if bufnr ~= except_bufnr and agent_defs[name] and vim.b[bufnr].luanphan_persist_term
          and (not keep_group or vim.w[win].luanphan_view_anchor ~= keep_group) then
        pcall(terminal_agent.close_window, win)
      end
    end
  end
end

function M.agent_icon(name)
  return agent_defs[name].icon
end

function M.display_title(name, title)
  local def = agent_defs[name]
  if def and def.display_title then return def.display_title(title) end
  return title
end

function M.names()
  return vim.list_slice(agent_order)
end

local function bind_agent_pane(win, bufnr, cwd)
  require("luanphan.agents.sidebar").attach(bufnr, win)
  M.map_jump_keys(bufnr)
  vim.keymap.set("n", "<leader>fN", function()
    agent_container:pick(cwd)
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Select terminal agent" })
end

local function layout_agent(win, width, col, height, geometry, style)
  local sidebar = require("luanphan.agents.sidebar")
  local anchor = vim.w[win].luanphan_view_anchor or win
  if not geometry then
    sidebar.layout(anchor, width, col, height)
    return
  end
  local cwd = vim.b[vim.api.nvim_win_get_buf(win)].luanphan_agent_cwd
  local panes = agent_container:display(anchor, cwd, geometry, style)
  if panes then
    for _, pane in ipairs(panes) do
      local tab = pane.tab
      if pane.opened or pane.win == anchor then
        agent_container:bind(tab.bufnr, cwd)
        bind_agent_pane(pane.win, tab.bufnr, cwd)
      end
      local api = apis[tab.agent] or setup_agent(tab.agent)
      api.prepare_tile(pane.win, pane.opened)
    end
  else
    local buf = vim.api.nvim_win_get_buf(anchor)
    local name = vim.b[buf].luanphan_agent_name
    agent_container:attach(anchor, buf, name .. ":" .. buf, cwd)
    bind_agent_pane(anchor, buf, cwd)
    apis[name].prepare_tile(anchor, false)
  end
  sidebar.layout(anchor, width, col, height)
  sidebar.refresh()
end

local function get_agent(name)
  if apis[name] then
    return apis[name]
  end

  local def = agent_defs[name]
  local sidebar = require("luanphan.agents.sidebar")
  apis[name] = terminal_agent.create({
    status_name = name,
    native_status = def.native_status,
    g_bufnr = def.g_bufnr,
    notify_prefix = def.notify_prefix,
    augroup_prefix = def.augroup_prefix,
    hint_open = agent_key,
    defaults = def.defaults,
    on_float_layout = layout_agent,
    on_prepare = function(win)
      agent_container:reserve(win)
    end,
    on_show = function(bufnr, win, cwd)
      jumplist.record(bufnr)
      if sessions.supported(name) then
        local seconds, microseconds = vim.uv.gettimeofday()
        vim.b[bufnr].luanphan_agent_saved_use = seconds + microseconds / 1000000
        sessions.save(bufnr)
      end
      agent_container:attach(win, bufnr, name .. ":" .. bufnr, cwd)
      bind_agent_pane(win, bufnr, cwd)
      apis[name].layout(win)
    end,
    on_close = function(bufnr, cwd)
      local id = sessions.supported(name) and vim.b[bufnr].luanphan_agent_thread_id
      local win = vim.fn.bufwinid(bufnr)
      local reflow = win ~= -1 and win ~= vim.api.nvim_get_current_win() and vim.w[win].luanphan_view_anchor
      agent_container:forget(name .. ":" .. bufnr, bufnr, cwd)
      vim.schedule(function()
        if id and type(vim.v.exiting) ~= "number" then
          sessions.forget_buffer(bufnr, name, id)
        end
        if reflow and vim.api.nvim_win_is_valid(reflow) then M.refresh_tabs(reflow) end
        sidebar.refresh()
      end)
    end,
    on_quit = function(bufnr, cwd)
      local tabs = open_tabs(cwd, bufnr)
      local next_tab
      for index, tab in ipairs(tabs) do
        if tab.bufnr == bufnr then
          next_tab = index > 1 and tabs[index - 1] or tabs[2]
          break
        end
      end
      agent_container:forget(name .. ":" .. bufnr, bufnr, cwd)
      return function()
        if next_tab and jump_available(next_tab.bufnr)
          and M.open(next_tab.agent, next_tab.bufnr, { view_mode = true }) then
          return
        end
        if not jump_session(1, 1) then jump_session(-1, 1) end
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
    opts = vim.tbl_extend("force", opts or {}, { reuse_win = vim.w[visible.win].luanphan_view_anchor or visible.win })
  else
    close_visible_agents(target)
  end
  if target then
    return setup_agent(name).focus(target, opts)
  end
  return setup_agent(name).new(opts)
end

function M.new(name, opts)
  if not agent_defs[name] then
    return false
  end
  local visible = visible_agent()
  if visible then
    setup_agent(visible.name).save_view(visible.win)
    close_visible_agents(visible.bufnr)
    opts = vim.tbl_extend("force", opts or {}, { reuse_win = vim.w[visible.win].luanphan_view_anchor or visible.win })
  end
  return setup_agent(name).new(opts)
end

function M.resume(session, opts)
  if not sessions.supported(session.agent) or not sessions.valid_id(session.thread_id) then return false end
  local args = agent_defs[session.agent].resume(session.thread_id)
  return M.new(session.agent, vim.tbl_extend("force", opts or {}, {
    args = args,
    thread_id = session.thread_id,
    agent_label = session.agent_label,
  }))
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
  require("luanphan.recent_paths").touch(vim.fn.getcwd())
  if M.hide() then return end
  local active = most_recent_tab(vim.fn.getcwd())
  local default = M.default_agent()
  if not active then
    local saved = sessions.latest(vim.fn.getcwd())
    if saved then return M.resume(saved) end
  end
  M.open(active and active.agent or default, active and active.bufnr or nil)
end

local function restore_on_first_ui()
  if vim.g.luanphan_agent_startup_restored or vim.v.vim_did_enter == 0 or #vim.api.nvim_list_uis() == 0 then return end
  vim.g.luanphan_agent_startup_restored = true
  local cwd = vim.fn.getcwd()
  if visible_agent() or most_recent_tab(cwd) then return end
  local saved = sessions.latest(cwd)
  if saved then M.resume(saved, { view_mode = true }) end
end

local function receive_terminal_event(args)
  local bufnr = args.buf
  local name = vim.b[bufnr].luanphan_agent_name
  local def = agent_defs[name]
  local sequence = args.data and args.data.sequence
  if not name or not sequence then return end
  local osc_status = status.from_osc(sequence)
  if osc_status then status.update(bufnr, osc_status) end
  local title = sequence:match("^\27%][02];(.*)$")
  -- Decoders defer persistence and redraws until the terminal callback has returned.
  local function emit(event)
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.b[bufnr].luanphan_agent_name ~= name then return end
    status.update(bufnr, event.status)
    local changed_id = sessions.update(bufnr, event)
    if changed_id then
      require("luanphan.agents.sidebar").refresh(true)
    elseif event.refresh_title then
      require("luanphan.agents.sidebar").update_title(bufnr)
    end
  end
  if def and def.decode_event then
    def.decode_event(bufnr, { sequence = sequence, title = title, status = osc_status }, emit)
  elseif title then
    vim.schedule(function() emit({ refresh_title = true }) end)
  end
end

function M.hide()
  local hidden = false
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local bufnr = vim.api.nvim_win_get_buf(win)
      if vim.bo[bufnr].filetype == "agent-sidebar"
        or (vim.bo[bufnr].buftype == "terminal"
        and vim.b[bufnr].luanphan_persist_term
        and not vim.b[bufnr].luanphan_toggleterm)
      then
        local ok, closed = pcall(terminal_agent.close_window, win)
        hidden = (ok and closed) or hidden
      end
    end
  end
  return hidden
end

function M.send_selection(name)
  local visible = visible_agent()
  local active = most_recent_tab(vim.fn.getcwd())
  name = name or (visible and visible.name) or (active and active.agent) or M.default_agent()
  if not agent_defs[name] then
    return false
  end
  local target = agent_buffer(name, vim.fn.getcwd())
  local visible = visible_agent()
  local opts
  if visible and visible.bufnr ~= target then
    setup_agent(visible.name).save_view(visible.win)
    close_visible_agents(visible.bufnr)
    opts = { reuse_win = vim.w[visible.win].luanphan_view_anchor or visible.win }
  else
    close_visible_agents(target)
  end
  setup_agent(name).send_selection(target, opts)
  return true
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
  new = function()
    M.new(M.default_agent())
  end,
  picker_title = "Terminal Agents",
  picker_opts = {
    layout_strategy = "center",
    layout_config = { width = 0.3, height = 0.25 },
  },
  empty_message = "no terminal agents registered",
  cycle_desc = "Next terminal agent",
  new_desc = "New default terminal agent",
})

function M.refresh_tabs(win)
  local bufnr = vim.api.nvim_win_get_buf(win)
  if vim.w[win].luanphan_view_anchor then
    setup_agent(vim.b[bufnr].luanphan_agent_name).layout(win)
  else
    agent_container:render(win, vim.b[bufnr].luanphan_agent_cwd)
  end
end

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
    end or nil,
    config = function()
      setup_agent(name)
    end,
  }
end

for _, name in ipairs(agent_order) do
  M[#M + 1] = agent_spec(name)
end

return M
