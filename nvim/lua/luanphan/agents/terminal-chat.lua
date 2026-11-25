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

M.running = terminal_window.running

local BASE_DEFAULTS = {
  cmd = "agent",
  args = {},
  resize_debounce_ms = 250,
  float_border = "single",
  float_zindex = 45,
  scrollback = nil,
  max_send_chars = 256 * 1024,
  defer_send_ms = 200,
  send_mode = "lines_only",
  detach_on_quit = false,
}

local TERMINAL_WINHIGHLIGHT = "NormalFloat:Normal,EndOfBuffer:,WinBar:Normal,WinBarNC:Normal,"
  .. "TabLineSel:Title,TabLine:LineNr,TabLineFill:Normal"

---@param profile table
---@field status_name? string stable name used by the cross-process status store
---@field shell? boolean forward Ctrl+L to an interactive shell
---@field status? table provider status options
---@field new_session_id? fun(): string
---@field g_bufnr string vim.g key for buffer reuse after reload
---@field notify_prefix string prefix for :vim.notify
---@field augroup_prefix string prefix for autocmd groups
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
    g_bufnr = "terminal_agent_bufnr",
    notify_prefix = "terminal_agent",
    augroup_prefix = "TerminalAgent",
    hint_open = "<leader>xx",
    defaults = {},
  }, profile)

  local function nx(msg, level)
    vim.notify(profile.notify_prefix .. ": " .. msg, level or vim.log.levels.INFO)
  end


local state = {
  bufnrs = {},        ---@type table<string, integer[]>  cwd -> bufnrs
  visibility = {},    ---@type table<string, boolean>  cwd -> last-known visibility
  resize_timer = nil, ---@type userdata|nil
  float_geometry = nil, ---@type table|nil
}

local G_BUFNR = profile.g_bufnr
local status_options = profile.status or {}

local DEFAULTS = vim.tbl_deep_extend("force", vim.deepcopy(BASE_DEFAULTS), profile.defaults or {})

local config = vim.deepcopy(DEFAULTS)

local function cwd_key()
  return vim.fn.getcwd()
end

local function normalize_bufnrs(value)
  if type(value) ~= "table" then
    return {}
  end
  local result = {}
  for _, nr in ipairs(value) do
    if type(nr) == "number" then
      result[#result + 1] = nr
    end
  end
  return result
end

local function current_bufnr(cwd)
  local selected = nil
  local selected_sequence = -1
  for _, nr in ipairs(normalize_bufnrs(state.bufnrs[cwd or cwd_key()])) do
    if M.running(nr) then
      if vim.fn.bufwinid(nr) ~= -1 then
        return nr
      end
      local sequence = tonumber(vim.b[nr].luanphan_agent_last_used) or 0
      if sequence > selected_sequence then
        selected = nr
        selected_sequence = sequence
      end
    end
  end
  return selected
end

local function persist_map()
  -- vim.g accepts Lua tables; they're round-tripped as vim dicts. Only store valid bufnrs.
  local snap = {}
  for cwd, stored in pairs(state.bufnrs) do
    local bufnrs = {}
    for _, nr in ipairs(normalize_bufnrs(stored)) do
      if vim.api.nvim_buf_is_valid(nr) then
        bufnrs[#bufnrs + 1] = nr
      end
    end
    if #bufnrs > 0 then
      state.bufnrs[cwd] = bufnrs
      snap[cwd] = bufnrs
    else
      state.bufnrs[cwd] = nil
    end
  end
  vim.g[G_BUFNR] = snap
end

local function set_agent_bufnr(bufnr, cwd)
  cwd = cwd or cwd_key()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local bufnrs = normalize_bufnrs(state.bufnrs[cwd])
    if not vim.tbl_contains(bufnrs, bufnr) then
      bufnrs[#bufnrs + 1] = bufnr
    end
    state.bufnrs[cwd] = bufnrs
    pcall(function() vim.b[bufnr].luanphan_persist_term = true end)
    pcall(function() vim.b[bufnr].luanphan_agent_name = profile.status_name end)
    pcall(function() vim.b[bufnr].luanphan_agent_cwd = cwd end)
    pcall(function() vim.b[bufnr].luanphan_agent_instance = #bufnrs end)
    require("luanphan.terminal_references").attach(bufnr, cwd)
  else
    state.bufnrs[cwd] = nil
    state.float_geometry = nil
  end
  persist_map()
end

local function clear_bufnr_for_buf(bufnr)
  for cwd, stored in pairs(state.bufnrs) do
    local bufnrs = normalize_bufnrs(stored)
    for index = #bufnrs, 1, -1 do
      if bufnrs[index] == bufnr then
        table.remove(bufnrs, index)
      end
    end
    if #bufnrs ~= #normalize_bufnrs(stored) then
      state.bufnrs[cwd] = #bufnrs > 0 and bufnrs or nil
      persist_map()
      if profile.on_close then
        pcall(profile.on_close, bufnr, cwd)
      end
      return cwd
    end
  end
  return nil
end

local function merge(dst, src)
  for k, v in pairs(src) do
    dst[k] = v
  end
  return dst
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
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
  return nil
end

local function owns_buffer(bufnr)
  for _, stored in pairs(state.bufnrs) do
    for _, owned in ipairs(normalize_bufnrs(stored)) do
      if owned == bufnr then
        return true
      end
    end
  end
  return false
end

local function mark_terminal_used(bufnr)
  local sequence = (tonumber(vim.g.luanphan_agent_use_sequence) or 0) + 1
  vim.g.luanphan_agent_use_sequence = sequence
  vim.b[bufnr].luanphan_agent_last_used = sequence
end

local function valid_job_id(job)
  return type(job) == "number" and job > 0
end

local function save_terminal_view(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local bufnr = vim.api.nvim_win_get_buf(win)
  if not owns_buffer(bufnr) then
    return
  end
  local ok, view = pcall(vim.api.nvim_win_call, win, vim.fn.winsaveview)
  if not ok then
    return
  end
  vim.b[bufnr].luanphan_terminal_view = {
    follow = view.lnum >= vim.api.nvim_buf_line_count(bufnr),
    view = view,
  }
end

local function resume_terminal_view(win, bufnr, opts)
  mark_terminal_used(bufnr)
  if profile.on_show then
    pcall(profile.on_show, bufnr, win, vim.b[bufnr].luanphan_agent_cwd or cwd_key())
  end
  sync_terminal_grid(win, bufnr)
  local saved = vim.b[bufnr].luanphan_terminal_view
  local restore_saved = type(saved) == "table" and saved.follow == false and type(saved.view) == "table"
  if (opts and opts.view_mode) or restore_saved then
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
        if opts and opts.view_mode and vim.api.nvim_get_current_win() == win then
          vim.cmd("stopinsert")
        end
        if restore_saved then
          pcall(vim.api.nvim_win_call, win, function()
            vim.fn.winrestview(saved.view)
          end)
        end
      end
    end)
    return
  end

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
  local win = vim.api.nvim_open_win(bufnr, true, vim.tbl_extend("force", layout.body, {
    style = "minimal",
  }))
  if profile.on_float_layout then
    profile.on_float_layout(win, layout, true)
  end
  return win
end

local function save_float_geometry(win)
  local win_config = vim.api.nvim_win_get_config(win)
  state.float_geometry = {
    relative = win_config.relative,
    row = win_config.row,
    col = win_config.col,
    width = win_config.width,
    height = win_config.height,
  }
end

local function apply_agent_scrollback(buf)
  local n = config.scrollback
  if type(n) == "number" and n >= 1 and n <= 100000 and vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].scrollback = n
  end
end

local function configure_terminal_buffer(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if vim.bo[buf].buftype ~= "terminal" then
    local group = vim.api.nvim_create_augroup(profile.augroup_prefix .. "Configure_" .. buf, { clear = true })
    vim.api.nvim_create_autocmd("TermOpen", {
      group = group,
      buffer = buf,
      once = true,
      callback = function(args)
        configure_terminal_buffer(args.buf)
      end,
    })
    return
  end
  pcall(vim.treesitter.stop, buf)
  pcall(vim.api.nvim_buf_call, buf, function()
    vim.bo.syntax = ""
    vim.b.matchparen_timeout = 0
    vim.b.matchparen_insert_timeout = 0
  end)
end

local function configure_terminal_window(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  configure_terminal_buffer(vim.api.nvim_win_get_buf(win))
  local options = {
    breakindent = false,
    colorcolumn = "",
    concealcursor = "",
    conceallevel = 0,
    cursorbind = false,
    cursorcolumn = false,
    cursorline = false,
    diff = false,
    foldcolumn = "0",
    foldenable = false,
    foldexpr = "0",
    foldmethod = "manual",
    linebreak = false,
    list = false,
    number = false,
    relativenumber = false,
    scrollbind = false,
    smoothscroll = false,
    spell = false,
    statuscolumn = "",
    winblend = 0,
    winfixbuf = false,
    winfixheight = false,
    winfixwidth = false,
    winhighlight = TERMINAL_WINHIGHLIGHT,
    wrap = false,
  }
  for name, value in pairs(options) do
    pcall(vim.api.nvim_set_option_value, name, value, { win = win, scope = "local" })
  end
end

local function prepare_terminal_window(win)
  if profile.on_prepare then
    pcall(profile.on_prepare, win)
  end
end

local function term_buffer_alive(bufnr)
  return M.running(bufnr)
end

local function layout_float(win)
  if pending_tile_close[vim.w[win].luanphan_view_anchor] then return end
  local layout = get_float_layout()
  state.float_geometry = layout.body
  if profile.on_float_layout then
    profile.on_float_layout(win, layout)
  else
    vim.api.nvim_win_set_config(win, layout.body)
    sync_terminal_grid(win, vim.api.nvim_win_get_buf(win))
  end
end

local function sync_float_after_resize()
  local cur = current_bufnr()
  if not cur or not term_buffer_alive(cur) then
    return
  end
  local win = win_for_buf(cur)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  layout_float(win)
end

local function schedule_resize_sync()
  local ms = config.resize_debounce_ms
  if state.resize_timer then
    state.resize_timer:stop()
    state.resize_timer:close()
    state.resize_timer = nil
  end
  local timer = vim.loop.new_timer()
  state.resize_timer = timer
  timer:start(ms, 0, function()
    timer:stop()
    timer:close()
    if state.resize_timer == timer then
      state.resize_timer = nil
    end
    vim.schedule(sync_float_after_resize)
  end)
end

--- While the outer frame is resized, snap the float back to the last applied size so the PTY does not
--- get a SIGWINCH per drag step; apply the final size once idle.
local function on_vim_resized()
  if state.float_geometry then
    local cur = current_bufnr()
    if cur then
      local win = win_for_buf(cur)
      if win and vim.api.nvim_win_is_valid(win) and not vim.w[win].luanphan_view_anchor then
        vim.api.nvim_win_set_config(win, state.float_geometry)
      end
    end
  end
  schedule_resize_sync()
end

local function set_float_navigation_keymaps(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local opts = { buffer = bufnr, silent = true, nowait = true }
  if not profile.shell then vim.keymap.set("t", "<C-l>", "<Nop>", opts) end
  local function navigate(direction)
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) ~= bufnr then return end
    if profile.on_navigate then
      profile.on_navigate(win, direction)
    else
      pcall(M.close_window, win)
    end
  end
  for _, direction in ipairs({ "h", "j", "k", "l" }) do
    local key = "<C-" .. direction .. ">"
    vim.keymap.set("n", key, function() navigate(direction) end, opts)
  end
end

local function attach_status_tracking(bufnr, cwd, initial_status)
  if not profile.status_name or not status_options.track_submit then return end
  local agent_status = require("luanphan.agents.status")
  if initial_status then
    agent_status.write(profile.status_name, cwd, initial_status)
  end
  vim.keymap.set("t", "<CR>", function()
    agent_status.write(profile.status_name, cwd, "running")
    return vim.api.nvim_replace_termcodes("<CR>", true, false, true)
  end, { buffer = bufnr, expr = true, silent = true })
end

local function quit_action(buf)
  local cwd = vim.b[buf].luanphan_agent_cwd
  if cwd and profile.on_quit then
    local ok, action = pcall(profile.on_quit, buf, cwd)
    if ok and type(action) == "function" then return action end
  end
end

local function terminal_closed(buf)
  if vim.b[buf].luanphan_agent_quitting then return end
  local win = win_for_buf(buf)
  local tile = win and vim.w[win].luanphan_view_anchor
  local action = win and (not tile or win == vim.api.nvim_get_current_win()) and quit_action(buf)
  -- Let the closing tile select its neighbor before any pending resize reflows the panel.
  if action and tile then pending_tile_close[tile] = true end
  clear_bufnr_for_buf(buf)
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

local function attach_term_close(buf)
  if backend.on_exit(buf, function() terminal_closed(buf) end) then return end
  local ag = vim.api.nvim_create_augroup(profile.augroup_prefix .. "TermClose_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("TermClose", {
    group = ag,
    buffer = buf,
    once = true,
    callback = function() terminal_closed(buf) end,
  })
end

local function attach_quit_detach(buf)
  local managed = vim.b[buf].luanphan_agent_tmux_pane
  if not managed and not config.detach_on_quit then return end
  local ag = vim.api.nvim_create_augroup(profile.augroup_prefix .. "Quit_" .. buf, { clear = true })
  if managed then
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = ag,
      buffer = buf,
      once = true,
      callback = function()
        if type(vim.v.exiting) == "number" or not backend.running(buf) then return end
        clear_bufnr_for_buf(buf)
        vim.schedule(function() backend.stop(buf) end)
      end,
    })
  end
  if profile.on_quit then
    vim.api.nvim_create_autocmd("CmdlineLeave", {
      group = ag,
      buffer = buf,
      callback = function()
        if vim.fn.getcmdtype() ~= ":" or vim.v.event.abort then return end
        local command = vim.trim(vim.fn.getcmdline()):gsub("!$", "")
        if command == "" or not vim.startswith("quit", command) then return end
        if not M.running(buf) then return end
        -- Let TermClose choose a replacement before the window is closed.
        vim.cmd("let v:event.abort = v:true")
        vim.schedule(function()
          terminal_window.stop(buf)
        end)
      end,
    })
  end
  vim.api.nvim_create_autocmd("QuitPre", {
    group = ag,
    buffer = buf,
    once = true,
    callback = function()
      if managed then
        local action = quit_action(buf)
        vim.schedule(function()
          if type(vim.v.exiting) == "number" or not M.running(buf) then return end
          terminal_window.stop(buf)
          if action then pcall(action) end
        end)
        return
      end
      vim.b[buf].luanphan_agent_quitting = true
      local action = quit_action(buf)
      local ok, job = pcall(vim.fn.getbufvar, buf, "terminal_job_id")
      if ok and valid_job_id(job) then
        pcall(vim.fn.jobstop, job)
        pcall(vim.fn.jobwait, { job }, 1000)
      end
      clear_bufnr_for_buf(buf)
      vim.schedule(function()
        if action then pcall(action) end
        if vim.api.nvim_buf_is_valid(buf) then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
      end)
    end,
  })
end

--- After <leader>src, reconnect to any surviving agent terminal buffers.
local function restore_agent_bufnr()
  local stored = vim.g[G_BUFNR]
  state.bufnrs = {}
  if type(stored) == "table" then
    for cwd, value in pairs(stored) do
      if type(cwd) == "string" then
        for index, nr in ipairs(normalize_bufnrs(value)) do
          if term_buffer_alive(nr) then
            state.bufnrs[cwd] = state.bufnrs[cwd] or {}
            state.bufnrs[cwd][#state.bufnrs[cwd] + 1] = nr
            pcall(function() vim.b[nr].luanphan_persist_term = true end)
            pcall(function() vim.b[nr].luanphan_agent_name = profile.status_name end)
            pcall(function() vim.b[nr].luanphan_agent_cwd = cwd end)
            pcall(function() vim.b[nr].luanphan_agent_instance = index end)
            attach_term_close(nr)
            attach_quit_detach(nr)
            apply_agent_scrollback(nr)
            set_float_navigation_keymaps(nr)
            attach_status_tracking(nr, cwd)
            require("luanphan.terminal_references").attach(nr, cwd)
          end
        end
      end
    end
  end
  persist_map()
  local cur = current_bufnr()
  if cur then
    local rwin = win_for_buf(cur)
    if rwin then
      prepare_terminal_window(rwin)
      configure_terminal_window(rwin)
      if profile.on_show then
        pcall(profile.on_show, cur, rwin, vim.b[cur].luanphan_agent_cwd or cwd_key())
      end
      if profile.on_float_layout then
        sync_float_after_resize()
      else
        sync_terminal_grid(rwin, cur)
      end
    end
  end
end

local function register_terminal(buf, cwd, initial_status)
  configure_terminal_buffer(buf)
  if status_options.initial and not vim.b[buf].luanphan_agent_program_status then
    require("luanphan.agents.status").update(buf, status_options.initial)
  end
  apply_agent_scrollback(buf)
  set_agent_bufnr(buf, cwd)
  attach_term_close(buf)
  attach_quit_detach(buf)
  set_float_navigation_keymaps(buf)
  attach_status_tracking(buf, cwd, initial_status)
end

local function start_terminal(buf, cwd, opts)
  local thread_id = opts and opts.thread_id
  if not thread_id and profile.new_session_id then thread_id = profile.new_session_id() end
  local label = opts and opts.agent_label
  vim.b[buf].luanphan_agent_thread_id = thread_id
  vim.b[buf].luanphan_agent_saved_label = label
  local geometry = get_float_layout().body
  local win = win_for_buf(buf)
  local width = win and vim.api.nvim_win_get_width(win) or geometry.width
  local height = win and vim.api.nvim_win_get_height(win) or geometry.height
  local data = {
    cwd = cwd,
    workspace = require("luanphan.plugins.worktree").agent_workspace(cwd),
    agent = profile.status_name or profile.notify_prefix,
    thread_id = thread_id,
    label = label or profile.status_name or profile.notify_prefix,
  }
  local ok, err = backend.launch(buf, command_for_agent(opts), data, width, math.max(1, height - 1))
  if not ok then
    nx("could not launch tmux pane: " .. (err or "attach failed"), vim.log.levels.ERROR)
    vim.api.nvim_buf_delete(buf, { force = true })
    return false
  end
  register_terminal(buf, cwd, "idle")
  return true
end

local function open_terminal(opts, on_start)
  local buf = vim.api.nvim_create_buf(false, true)
  local reuse_win = opts and opts.reuse_win
  local win
  if reuse_win and vim.api.nvim_win_is_valid(reuse_win) then
    win = reuse_win
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_set_current_win(win)
  else
    win = open_agent_float(buf)
  end
  vim.api.nvim_win_set_config(win, { zindex = config.float_zindex })
  prepare_terminal_window(win)
  configure_terminal_window(win)
  save_float_geometry(win)
  local cwd = cwd_key()
  if not start_terminal(buf, cwd, opts) then return end
  if on_start then on_start(buf) end
  resume_terminal_view(win, buf, opts)
  return buf
end

local function show_terminal(bufnr, opts)
  local cur = bufnr or current_bufnr()
  if not cur then return end
  local reuse_win = opts and opts.reuse_win
  local win
  if reuse_win and vim.api.nvim_win_is_valid(reuse_win) then
    win = reuse_win
    prepare_terminal_window(win)
    vim.api.nvim_win_set_buf(win, cur)
    vim.api.nvim_set_current_win(win)
  else
    local placeholder = vim.api.nvim_create_buf(false, true)
    win = open_agent_float(placeholder)
    prepare_terminal_window(win)
    vim.api.nvim_win_set_buf(win, cur)
    pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
  end
  vim.api.nvim_win_set_config(win, { zindex = config.float_zindex })
  configure_terminal_window(win)
  save_float_geometry(win)
  apply_agent_scrollback(cur)
  set_float_navigation_keymaps(cur)
  resume_terminal_view(win, cur, opts)
end

local API = {}

function API.toggle()
  local cur = current_bufnr()
  if cur and term_buffer_alive(cur) then
    local win = win_for_buf(cur)
    if win then
      M.close_window(win)
      return
    end
    show_terminal()
    return
  end
  -- Stale or missing entry for this cwd; open a fresh one.
  set_agent_bufnr(nil)
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
  if not cur or not term_buffer_alive(cur) then
    nx("no agent terminal — use " .. profile.hint_open .. " to open", vim.log.levels.INFO)
    return false
  end
  local win = win_for_buf(cur)
  if not win then
    show_terminal(cur, opts)
    return true
  end
  configure_terminal_window(win)
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
    configure_terminal_window(win)
    local saved = vim.b[buf].luanphan_terminal_view
    if saved and saved.follow == false and saved.view then
      vim.api.nvim_win_call(win, function() vim.fn.winrestview(saved.view) end)
    end
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
    if target_bufnr and term_buffer_alive(target_bufnr) then
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
    if not cur or not term_buffer_alive(cur) then
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
  if not cur or not term_buffer_alive(cur) then
    set_agent_bufnr(nil)
    open_terminal(opts)
    vim.defer_fn(function()
      deliver(1)
    end, config.defer_send_ms)
    return
  end

  deliver(1)
end

function API.setup(opts)
  config = merge(vim.deepcopy(DEFAULTS), opts or {})
  if not config.resize_debounce_ms or config.resize_debounce_ms <= 0 then
    config.resize_debounce_ms = 250
  end
  restore_agent_bufnr()

  vim.api.nvim_create_autocmd("WinLeave", {
    group = vim.api.nvim_create_augroup(profile.augroup_prefix .. "View", { clear = true }),
    callback = function(args)
      if owns_buffer(args.buf) then
        save_terminal_view(win_for_buf(args.buf))
      end
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = vim.api.nvim_create_augroup(profile.augroup_prefix .. "Resize", { clear = true }),
    callback = on_vim_resized,
  })

  if profile.on_float_layout then
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = vim.api.nvim_create_augroup(profile.augroup_prefix .. "FloatSettings", { clear = true }),
      callback = function(args)
        local path = vim.uv.fs_realpath(require("luanphan.global_settings").config_path())
        if path and path == vim.uv.fs_realpath(vim.api.nvim_buf_get_name(args.buf)) then
          sync_float_after_resize()
        end
      end,
    })
  end

  -- Per-worktree visibility: remember whether the agent was visible in the old cwd;
  -- auto-restore when returning to a cwd where it was visible last.
  vim.api.nvim_create_autocmd("DirChangedPre", {
    group = vim.api.nvim_create_augroup(profile.augroup_prefix .. "DirPre", { clear = true }),
    callback = function()
      if preserve_windows then return end
      local old = cwd_key()
      local cur = current_bufnr(old)
      if not cur or not term_buffer_alive(cur) then
        state.visibility[old] = false
        return
      end
      local win = win_for_buf(cur)
      if win then
        state.visibility[old] = true
        pcall(M.close_window, win)
      else
        state.visibility[old] = false
      end
    end,
  })

  vim.api.nvim_create_autocmd("DirChanged", {
    group = vim.api.nvim_create_augroup(profile.augroup_prefix .. "Dir", { clear = true }),
    callback = function()
      if preserve_windows then return end
      local new = cwd_key()
      if not state.visibility[new] then return end
      local cur = current_bufnr(new)
      if not cur or not term_buffer_alive(cur) then return end
      if win_for_buf(cur) then return end
      show_terminal()
    end,
  })

end

  return API
end

return M
