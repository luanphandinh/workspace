local M = {}
local sessions = require("luanphan.agents.sessions")
local status = require("luanphan.agents.status")
local view_container = require("luanphan.view_container")
local terminal = require("luanphan.view_container.terminal")

local agent_order = { "codex", "cursor", "claude", "terminal" }
local agent_key = "<leader>a"
local picker_opts = { layout_strategy = "center", layout_config = { width = 0.3, height = 0.25 } }

local agent_defs = { terminal = require("luanphan.view_container.shell") }
for _, name in ipairs(agent_order) do
  local def = agent_defs[name] or require("luanphan.agents.plugins." .. name .. "." .. name)
  def.status = vim.tbl_extend("force", { decode = status.from_osc }, def.status or {})
  agent_defs[name] = def
end

local lifecycle

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
  end, picker_opts)
end

function M.agent_icon(name)
  return agent_defs[name].icon
end

function M.display_title(name, title)
  local def = agent_defs[name]
  if def and def.display_title then return def.display_title(title) end
  return title
end

local function bind_actions(bufnr, sidebar)
  local opts = { buffer = bufnr, silent = true, nowait = true }
  if sidebar then vim.keymap.set("n", agent_key, M.toggle, { buffer = bufnr }) end
  -- Keep the editor's New buffer mapping from replacing a panel buffer.
  vim.keymap.set("n", "<leader>fn", "<Nop>", opts)
  vim.keymap.set("n", "<leader>nt", function() M.new("terminal") end,
    vim.tbl_extend("force", opts, { desc = "New terminal" }))
  vim.keymap.set("n", "<leader>na", function() M.new(M.default_agent()) end,
    vim.tbl_extend("force", opts, { desc = "New default terminal agent" }))
  vim.keymap.set("n", "<leader>nA", function() M.container:pick() end,
    vim.tbl_extend("force", opts, { desc = "Select terminal agent" }))
  if not vim.b[bufnr].luanphan_agent_new_menu then
    local ok, which_key = pcall(require, "which-key")
    if ok then
      which_key.add({ { "<leader>n", group = "New", buffer = bufnr } })
      vim.b[bufnr].luanphan_agent_new_menu = true
    end
  end
end

function M.toggle()
  require("luanphan.recent_paths").touch(vim.fn.getcwd())
  return view_container.toggle_panel(M, lifecycle.reopen)
end

local function receive_terminal_event(args)
  local bufnr = args.buf
  local name = vim.b[bufnr].luanphan_view_kind
  local def = agent_defs[name]
  local sequence = args.data and args.data.sequence
  if not name or not sequence then return end
  local status_options = def and def.status
  local osc_status = status_options and status_options.decode and status_options.decode(sequence)
  if osc_status then
    status.update(bufnr, osc_status)
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then lifecycle.remember(bufnr) end
    end)
  end
  local title = terminal.request_title(sequence)
  -- Decoders defer persistence and redraws until the terminal callback has returned.
  local function emit(event)
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.b[bufnr].luanphan_view_kind ~= name then return end
    status.update(bufnr, event.status)
    local changed_id = sessions.update(bufnr, event)
    lifecycle.remember(bufnr)
    local bar = M.container.opts.bar()
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

function M.send_selection(name)
  local cwd, target = M.container:context(), nil
  if name then
    if not is_agent(name) then return false end
    target = M.container:recent_pane(cwd, name)
  else
    local visible = lifecycle.visible()
    target = visible and is_agent(visible.kind) and visible.bufnr or M.container:recent_pane(cwd, nil, false, is_agent)
    name = target and vim.b[target].luanphan_view_kind or M.default_agent()
  end
  lifecycle.provider(name).send_selection(target)
  return true
end

lifecycle = require("luanphan.view_container.managed_panel").create(M, {
  backend = require("luanphan.agents.tmux"),
  providers = agent_defs, kinds = agent_order, sessions = sessions,
  create = require("luanphan.agents.terminal-chat").create,
  default_kind = M.default_agent, hint_open = agent_key,
  workspace = function(cwd) return require("luanphan.plugins.worktree").agent_workspace(cwd) end,
  display_title = M.display_title,
  group = "LuanphanAgentPanel", startup_group = "LuanphanAgentStartup", startup_flag = "luanphan_agent_startup_restored",
  view = {
    bind_actions = bind_actions,
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
      title = M.display_title(buffer.luanphan_view_kind, title)
      if type(title) ~= "string" or title == "" or title == vim.api.nvim_buf_get_name(buf) then
        return buffer.luanphan_view_saved_label
      end
      return title
    end,
    choices = agent_choices,
    picker_title = "Terminal Agents",
    picker_opts = picker_opts,
    empty_message = "no terminal agents registered",
    cycle_desc = "Next agent session",
  },
})

M.spec = lifecycle.plugin_specs({
  { agent_key, M.toggle, mode = "n", desc = "Toggle agents" },
  { agent_key, function() M.send_selection() end, mode = { "x", "s" }, desc = "Send to active agent" },
  { "<leader>sad", M.pick_default_agent, desc = "Default agent" },
}, receive_terminal_event)

return M
