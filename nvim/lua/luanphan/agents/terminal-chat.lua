-- Shared terminal agent factory used by the lazy agent specs.
--
-- Agent terminals are scoped per-worktree: each cwd owns its agent buffers.
-- Switching worktree (|worktree.lua|) hides but does not kill these buffers.
--
-- Send format for selections:
--   - lines_only (default): @relative/path:<start>-<end>
--   - full: @path:start-end header, then full selected text (truncated by max_send_chars).

local M = {}
local view_container = require("luanphan.view_container")
local terminal_pane = require("luanphan.view_container.terminal")
local terminal_window = require("luanphan.terminal.window")
local backend = require("luanphan.agents.tmux")
local sync_terminal_grid = terminal_window.sync_grid
local preserve_windows = false
local pending_tile_close = {}

function M.close_window(win)
  return view_container.close_group(view_container.group_anchor(win))
end

function M.with_preserved_windows(callback)
  local previous = preserve_windows
  preserve_windows = true
  local ok, result = pcall(callback)
  preserve_windows = previous
  if not ok then error(result) end
  return result
end

function M.track_directory(group, visible, restore)
  local saved = {}
  vim.api.nvim_create_autocmd({ "DirChangedPre", "DirChanged" }, {
    group = group,
    callback = function(event)
      if preserve_windows then return end
      local cwd = vim.fn.getcwd()
      if event.event == "DirChangedPre" then
        local win, pane = visible(cwd)
        saved[cwd] = pane or win
        if win then pcall(M.close_window, win) end
      elseif saved[cwd] then
        restore(cwd, saved[cwd])
      end
    end,
  })
end

M.running = terminal_window.running

local BASE_DEFAULTS = {
  cmd = "agent",
  args = {},
  float_border = "single",
  float_zindex = 45,
  scrollback = nil,
  max_send_chars = 256 * 1024,
  defer_send_ms = 200,
  send_mode = "lines_only",
}

local TERMINAL_WINHIGHLIGHT = "NormalFloat:Normal,EndOfBuffer:,WinBar:Normal,WinBarNC:Normal,"
  .. "TabLineSel:Title,TabLine:LineNr,TabLineFill:Normal"

---@param profile table
---@field name? string stable provider name
---@field shell? boolean forward Ctrl+L to an interactive shell
---@field status? table provider status options
---@field new_session_id? fun(): string
---@field hint_open string hint when no terminal (e.g. "<leader>a")
---@field defaults? table merged into BASE_DEFAULTS (cmd, args, …)
---@field on_prepare? fun(win: integer)
---@field on_show? fun(bufnr: integer, win: integer, cwd: string)
---@field on_close? fun(bufnr: integer, cwd: string)
---@field on_quit? fun(bufnr: integer, cwd: string): function?
---@field on_navigate? fun(win: integer, direction: string)
---@field on_float_layout? fun(win: integer, layout: table, opening?: boolean)
function M.create(profile)
  profile = vim.tbl_extend("force", {
    name = "terminal_agent",
    hint_open = "<leader>xx",
    defaults = {},
  }, profile)

  local provider_name = profile.name
  local augroup_name = "LuanphanAgent_" .. provider_name
  local function nx(msg, level)
    vim.notify(provider_name .. ": " .. msg, level or vim.log.levels.INFO)
  end


local status_options = profile.status or {}

local DEFAULTS = vim.tbl_deep_extend("force", vim.deepcopy(BASE_DEFAULTS), profile.defaults or {})

local config = vim.deepcopy(DEFAULTS)

local function cwd_key()
  return vim.fn.getcwd()
end

local function current_bufnr(cwd)
  local selected
  local selected_sequence = -1
  for _, pane in ipairs(backend.panes(provider_name, cwd or cwd_key())) do
    local buf = pane.bufnr
    if vim.fn.bufwinid(buf) ~= -1 then return buf end
    local sequence = tonumber(vim.b[buf].luanphan_agent_last_used) or 0
    if sequence > selected_sequence then
      selected, selected_sequence = buf, sequence
    end
  end
  return selected
end

local function command_for_agent(opts)
  local cmd = config.cmd
  if type(cmd) == "function" then cmd = cmd() end
  local args = (opts and opts.args) or config.args or {}
  if type(cmd) == "table" then
    local out = vim.deepcopy(cmd)
    vim.list_extend(out, args)
    return out
  end
  local out = { cmd }
  vim.list_extend(out, args)
  return out
end

local function buf_shortpath(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return "[No Name]"
  end
  return vim.fn.fnamemodify(name, ":.")
end

local function win_for_buf(bufnr)
  return vim.fn.win_findbuf(bufnr)[1]
end

local function mark_terminal_used(bufnr)
  local sequence = (tonumber(vim.g.luanphan_agent_use_sequence) or 0) + 1
  vim.g.luanphan_agent_use_sequence = sequence
  vim.b[bufnr].luanphan_agent_last_used = sequence
end

local function save_terminal_view(win)
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local buf = vim.api.nvim_win_get_buf(win)
  if backend.running(buf) then
    terminal_window.save_view(win, buf)
  end
end

local function resume_terminal_view(win, bufnr, opts)
  mark_terminal_used(bufnr)
  if profile.on_show then
    pcall(profile.on_show, bufnr, win, vim.b[bufnr].luanphan_agent_cwd or cwd_key())
  end
  sync_terminal_grid(win, bufnr)
  if opts and opts.view_mode then
    vim.schedule(function()
      if vim.api.nvim_get_current_win() == win and vim.api.nvim_win_get_buf(win) == bufnr then
        vim.cmd("stopinsert")
      end
    end)
    return
  end
  if terminal_window.is_scrolled(bufnr) then return end

  vim.defer_fn(function()
    if vim.api.nvim_win_is_valid(win)
        and vim.api.nvim_win_get_buf(win) == bufnr
        and vim.api.nvim_get_current_win() == win then
      vim.cmd("startinsert")
    end
  end, 10)
end

local function get_float_layout()
  local settings = profile.on_float_layout and require("luanphan.global_settings").read().agent_float
  return view_container.layout(settings or { total_width_percent = 80 }, {
    border = config.float_border or "single", zindex = config.float_zindex, min_height = 12,
  })
end

local function open_agent_float(bufnr)
  local layout = get_float_layout()
  local win = view_container.open_float(layout, bufnr, true)
  if profile.on_float_layout then
    profile.on_float_layout(win, layout, true)
  end
  return win
end

local function apply_agent_scrollback(buf)
  local n = config.scrollback
  if type(n) == "number" and n >= 1 and n <= 100000 and vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].scrollback = n
  end
end

local function prepare_terminal_window(win)
  if profile.on_prepare then
    pcall(profile.on_prepare, win)
  end
end

local function layout_float(win)
  if not vim.api.nvim_win_is_valid(win) then return end
  if pending_tile_close[vim.w[win].luanphan_view_anchor] then return end
  local layout = get_float_layout()
  if profile.on_float_layout then
    profile.on_float_layout(win, layout)
  else
    vim.api.nvim_win_set_config(win, layout.body)
    sync_terminal_grid(win, vim.api.nvim_win_get_buf(win))
  end
end

local navigate = profile.on_navigate or function(win) pcall(M.close_window, win) end

local function bind_terminal(buf)
  terminal_pane.bind_navigation(buf, navigate)
  if not profile.shell then
    vim.keymap.set("t", "<C-l>", "<Nop>", { buffer = buf, silent = true, nowait = true })
  end
end

local function quit_action(buf)
  local cwd = vim.b[buf].luanphan_agent_cwd
  if cwd and profile.on_quit then
    local ok, action = pcall(profile.on_quit, buf, cwd)
    if ok and type(action) == "function" then return action end
  end
end

local function notify_close(buf)
  if profile.on_close then
    pcall(profile.on_close, buf, vim.b[buf].luanphan_agent_cwd)
  end
end

local function terminal_closed(buf)
  local win = win_for_buf(buf)
  local tile = win and vim.w[win].luanphan_view_anchor
  local action = win and (not tile or win == vim.api.nvim_get_current_win()) and quit_action(buf)
  -- Let the closing tile select its neighbor before any pending resize reflows the panel.
  if action and tile then pending_tile_close[tile] = true end
  notify_close(buf)
  vim.schedule(function()
    if action and tile then pending_tile_close[tile] = nil end
    if action and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      pcall(action)
    end
    if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      if tile and win ~= tile then
        pcall(vim.api.nvim_win_close, win, true)
      else
        pcall(M.close_window, win)
      end
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end)
end

local function attach_window_events(buf)
  local ag = vim.api.nvim_create_augroup(augroup_name .. "_Window_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = ag,
    buffer = buf,
    callback = function()
      save_terminal_view(vim.api.nvim_get_current_win())
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = ag,
    buffer = buf,
    once = true,
    callback = function()
      if type(vim.v.exiting) == "number" or not backend.running(buf) then return end
      notify_close(buf)
      vim.schedule(function() backend.stop(buf) end)
    end,
  })
  terminal_pane.bind_quit(buf, ag, function(direct)
    if not backend.running(buf) then return end
    local action = direct and quit_action(buf)
    return function()
      if backend.stop(buf) and action then pcall(action) end
    end
  end)
end

local function register_terminal(buf, cwd)
  terminal_pane.configure_buffer(buf)
  if status_options.initial and not vim.b[buf].luanphan_agent_program_status then
    require("luanphan.agents.status").update(buf, status_options.initial)
  end
  apply_agent_scrollback(buf)
  terminal_pane.set_reference_cwd(buf, cwd)
  backend.on_exit(buf, function() terminal_closed(buf) end)
  attach_window_events(buf)
  bind_terminal(buf)
end

local function start_terminal(buf, cwd, opts)
  local thread_id = opts and opts.thread_id
  if not thread_id and profile.new_session_id then thread_id = profile.new_session_id() end
  local label = opts and opts.agent_label
  vim.b[buf].luanphan_agent_thread_id = thread_id
  vim.b[buf].luanphan_agent_saved_label = label
  local win = win_for_buf(buf)
  local geometry = not win and get_float_layout().body
  local width = win and vim.api.nvim_win_get_width(win) or geometry.width
  local height = win and vim.api.nvim_win_get_height(win) or geometry.height
  local data = {
    cwd = cwd,
    workspace = require("luanphan.plugins.worktree").agent_workspace(cwd),
    agent = provider_name,
    thread_id = thread_id,
    label = label or provider_name,
  }
  local ok, err = backend.launch(buf, command_for_agent(opts), data, width, math.max(1, height - 1))
  if not ok then
    nx("could not launch tmux pane: " .. (err or "attach failed"), vim.log.levels.ERROR)
    vim.api.nvim_buf_delete(buf, { force = true })
    return false
  end
  register_terminal(buf, cwd)
  return true
end

local function mount_terminal(buf, opts)
  local win = opts and opts.reuse_win
  local placeholder
  if not win or not vim.api.nvim_win_is_valid(win) then
    -- Reserve the winbar before attaching a live terminal so its grid stays stable.
    if vim.bo[buf].buftype == "terminal" then placeholder = vim.api.nvim_create_buf(false, true) end
    win = open_agent_float(placeholder or buf)
  end
  prepare_terminal_window(win)
  if vim.api.nvim_win_get_buf(win) ~= buf then vim.api.nvim_win_set_buf(win, buf) end
  if placeholder then pcall(vim.api.nvim_buf_delete, placeholder, { force = true }) end
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_config(win, { zindex = config.float_zindex })
  terminal_pane.configure_window(win, TERMINAL_WINHIGHLIGHT)
  return win
end

local function open_terminal(opts, on_start)
  local buf = vim.api.nvim_create_buf(false, true)
  local win = mount_terminal(buf, opts)
  local cwd = cwd_key()
  if not start_terminal(buf, cwd, opts) then return end
  if on_start then on_start(buf) end
  resume_terminal_view(win, buf, opts)
  return buf
end

local function show_terminal(bufnr, opts)
  local cur = bufnr or current_bufnr()
  if not cur then return end
  local win = mount_terminal(cur, opts)
  apply_agent_scrollback(cur)
  bind_terminal(cur)
  resume_terminal_view(win, cur, opts)
end

local API = {}

function API.toggle()
  local cur = current_bufnr()
  if cur and M.running(cur) then
    local win = win_for_buf(cur)
    if win then
      M.close_window(win)
      return
    end
    show_terminal()
    return
  end
  open_terminal()
end

function API.new(opts, on_start)
  return open_terminal(opts, on_start)
end

function API.start_hidden(cwd, opts)
  local buf = vim.api.nvim_create_buf(false, true)
  return start_terminal(buf, cwd, opts) and buf
end

function API.adopt(record)
  local data = record.data
  local buf = vim.api.nvim_create_buf(false, true)
  vim.b[buf].luanphan_agent_thread_id = data.thread_id
  vim.b[buf].luanphan_agent_saved_label = data.label
  vim.b[buf].luanphan_agent_program_status = data.status
  vim.b[buf].luanphan_agent_last_used = data.used
  vim.b[buf].luanphan_agent_saved_use = data.used_at
  if not backend.adopt(buf, record) then
    vim.api.nvim_buf_delete(buf, { force = true })
    return
  end
  register_terminal(buf, data.cwd)
  return buf
end

--- Focus an agent terminal, showing its buffer when hidden.
function API.focus(bufnr, opts)
  local cur = bufnr or current_bufnr()
  if not cur or not M.running(cur) then
    nx("no agent terminal — use " .. profile.hint_open .. " to open", vim.log.levels.INFO)
    return false
  end
  local win = win_for_buf(cur)
  if not win then
    show_terminal(cur, opts)
    return true
  end
  terminal_pane.configure_window(win, TERMINAL_WINHIGHLIGHT)
  vim.api.nvim_set_current_win(win)
  resume_terminal_view(win, cur, opts)
  return true
end

function API.save_view(win)
  save_terminal_view(win)
end

function API.layout(win)
  layout_float(win)
end

function API.prepare_tile(win, opened)
  if not vim.api.nvim_win_is_valid(win) then return end
  local buf = vim.api.nvim_win_get_buf(win)
  if opened then
    terminal_pane.configure_window(win, TERMINAL_WINHIGHLIGHT)
  end
  sync_terminal_grid(win, buf)
end

local function format_selection_payload(bufnr, lines, line_start, line_end)
  local path = buf_shortpath(bufnr)
  if path == "[No Name]" then
    nx("save the buffer to use @path:start-end", vim.log.levels.WARN)
    return nil
  end

  local header = string.format("@%s:%d-%d", path, line_start, line_end)
  if config.send_mode == "lines_only" then
    -- No trailing newline: terminal cursor stays on same line after @path:start-end.
    return header
  end

  local body = table.concat(lines, "\n")
  if #body > config.max_send_chars then
    body = body:sub(1, config.max_send_chars)
      .. "\n... [truncated after "
      .. config.max_send_chars
      .. " chars]"
    nx("selection truncated", vim.log.levels.WARN)
  end
  return header .. "\n\n" .. body .. "\n"
end

local function exit_visual_to_normal()
  -- Consume Escape before focusing the terminal, where it would interrupt the agent.
  vim.cmd.normal({ args = { vim.keycode("<Esc>") }, bang = true })
end

function API.send_selection(target_bufnr, opts)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].buftype ~= "" then
    nx("not supported in this buffer", vim.log.levels.WARN)
    exit_visual_to_normal()
    return
  end

  -- While still in Visual mode, '< and '> are the *previous* selection; use 'v' (visual start) and
  -- '.' (cursor) for the active selection. See :help `v
  local l1, l2 = vim.fn.line("v"), vim.fn.line(".")
  local line_start = math.min(l1, l2)
  local line_end = math.max(l1, l2)

  local lines = nil
  if config.send_mode == "full" then
    local vmode = vim.fn.visualmode()
    local start_pos = vim.fn.getpos("v")
    local end_pos = vim.fn.getpos(".")
    lines = vim.fn.getregion(start_pos, end_pos, { type = vmode })
    if not lines or #lines == 0 then
      nx("empty selection", vim.log.levels.INFO)
      exit_visual_to_normal()
      return
    end
  end

  exit_visual_to_normal()

  local payload = format_selection_payload(bufnr, lines, line_start, line_end)
  if not payload then
    return
  end

  local function target_terminal()
    if target_bufnr and M.running(target_bufnr) then
      return target_bufnr
    end
    return current_bufnr()
  end

  local function focus_term_win()
    local cur = target_terminal()
    if not cur then return end
    local w = win_for_buf(cur)
    if w then
      vim.api.nvim_set_current_win(w)
      vim.cmd("startinsert")
    end
  end

  local function deliver(attempt)
    attempt = attempt or 1
    local cur = target_terminal()
    if not cur or not M.running(cur) then
      if attempt < 3 then
        vim.defer_fn(function()
          deliver(attempt + 1)
        end, config.defer_send_ms)
        return
      end
      nx("terminal not ready", vim.log.levels.ERROR)
      return
    end

    local win = win_for_buf(cur)
    if not win then
      show_terminal(cur, opts)
    end

    if not terminal_window.send(cur, "\27[200~" .. payload .. "\27[201~") then
      nx("could not send to the terminal", vim.log.levels.ERROR)
      return
    end

    focus_term_win()
  end

  local cur = target_terminal()
  if not cur or not M.running(cur) then
    open_terminal(opts)
    vim.defer_fn(function()
      deliver(1)
    end, config.defer_send_ms)
    return
  end

  deliver(1)
end

function API.setup(opts)
  config = vim.tbl_extend("force", vim.deepcopy(DEFAULTS), opts or {})
  -- Rebind surviving panes after a config reload.
  for _, pane in ipairs(backend.panes(provider_name)) do
    register_terminal(pane.bufnr, pane.data.cwd)
  end
  local cur = current_bufnr()
  local win = cur and win_for_buf(cur)
  if win then
    prepare_terminal_window(win)
    terminal_pane.configure_window(win, TERMINAL_WINHIGHLIGHT)
    if profile.on_show then
      pcall(profile.on_show, cur, win, vim.b[cur].luanphan_agent_cwd)
    else
      sync_terminal_grid(win, cur)
    end
  end

  if not profile.on_float_layout then
    local group = vim.api.nvim_create_augroup(augroup_name, { clear = true })
    vim.api.nvim_create_autocmd("VimResized", {
      group = group,
      callback = function()
        local buf = current_bufnr()
        local visible_win = buf and win_for_buf(buf)
        if visible_win then layout_float(visible_win) end
      end,
    })
    M.track_directory(group, function(cwd)
      local buf = current_bufnr(cwd)
      return buf and win_for_buf(buf)
    end, function(cwd)
      local buf = current_bufnr(cwd)
      if buf and not win_for_buf(buf) then show_terminal(buf) end
    end)
  end
end

  return API
end

return M
