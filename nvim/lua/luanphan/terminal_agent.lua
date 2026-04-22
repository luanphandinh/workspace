-- Shared terminal agent (Cursor CLI, Claude CLI, etc.). Use |cursor_agent.lua| and |claude_agent.lua|
-- thin wrappers around |terminal_agent.create()|.
--
-- Agent terminals are scoped per-worktree: each cwd owns its own agent buffer.
-- Switching worktree (|worktree.lua|) hides but does not kill these buffers.
--
-- Send format for selections:
--   - lines_only (default): @relative/path:<start>-<end>
--   - full: @path:start-end header, then full selected text (truncated by max_send_chars).

local M = {}

local BASE_DEFAULTS = {
  window_mode = "float",
  cmd = "agent",
  args = {},
  split = "vertical",
  width = nil,
  height = nil,
  split_ratio = 0.45,
  lock_split = true,
  resize_debounce_ms = 250,
  float_border = "single",
  scrollback = nil,
  max_send_chars = 256 * 1024,
  defer_send_ms = 200,
  send_mode = "lines_only",
}

---@param profile table
---@field g_bufnr string vim.g key for buffer reuse after reload
---@field notify_prefix string prefix for :vim.notify
---@field augroup_prefix string prefix for autocmd groups (CursorAgent / ClaudeAgent)
---@field hint_open string hint when no terminal (e.g. "<leader>cc")
---@field defaults? table merged into BASE_DEFAULTS (cmd, args, …)
---@field keymaps table keys: toggle, send, optional focus
---@field map_desc? table optional desc.toggle, desc.send, desc.focus
function M.create(profile)
  profile = vim.tbl_extend("force", {
    g_bufnr = "terminal_agent_bufnr",
    notify_prefix = "terminal_agent",
    augroup_prefix = "TerminalAgent",
    hint_open = "<leader>xx",
    defaults = {},
    keymaps = {},
    map_desc = {},
  }, profile)

  local function nx(msg, level)
    vim.notify(profile.notify_prefix .. ": " .. msg, level or vim.log.levels.INFO)
  end


local state = {
  bufnrs = {},        ---@type table<string, integer>  cwd -> bufnr
  visibility = {},    ---@type table<string, boolean>  cwd -> last-known visibility
  resize_timer = nil, ---@type userdata|nil
  float_geometry = nil, ---@type table|nil
}

local G_BUFNR = profile.g_bufnr

local DEFAULTS = vim.tbl_deep_extend("force", vim.deepcopy(BASE_DEFAULTS), profile.defaults or {})

local config = vim.deepcopy(DEFAULTS)

local function cwd_key()
  return vim.fn.getcwd()
end

local function current_bufnr()
  local nr = state.bufnrs[cwd_key()]
  if type(nr) == "number" and vim.api.nvim_buf_is_valid(nr) then
    return nr
  end
  return nil
end

local function persist_map()
  -- vim.g accepts Lua tables; they're round-tripped as vim dicts. Only store valid bufnrs.
  local snap = {}
  for cwd, nr in pairs(state.bufnrs) do
    if type(nr) == "number" and vim.api.nvim_buf_is_valid(nr) then
      snap[cwd] = nr
    end
  end
  vim.g[G_BUFNR] = snap
end

local function set_agent_bufnr(bufnr, cwd)
  cwd = cwd or cwd_key()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    state.bufnrs[cwd] = bufnr
    pcall(function() vim.b[bufnr].luanphan_persist_term = true end)
  else
    state.bufnrs[cwd] = nil
    state.float_geometry = nil
  end
  persist_map()
end

local function clear_bufnr_for_buf(bufnr)
  for cwd, b in pairs(state.bufnrs) do
    if b == bufnr then
      state.bufnrs[cwd] = nil
      persist_map()
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

local function argv_for_termopen()
  local cmd = config.cmd
  local args = config.args or {}
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

--- Vertical split with new window on the right (does not change global 'splitright' afterward).
local function vsplit_right()
  local saved = vim.o.splitright
  vim.o.splitright = true
  vim.cmd("vsplit")
  vim.o.splitright = saved
end

--- @return integer|nil dim, string|nil axis "w"|"h"
local function get_target_split_dims()
  if config.split == "vertical" then
    if config.width then
      local total = vim.o.columns
      return math.max(20, math.min(tonumber(config.width) or 80, total - 10)), "w"
    elseif config.split_ratio then
      local total = vim.o.columns
      local w = math.floor(total * config.split_ratio)
      return math.max(20, math.min(w, total - 10)), "w"
    end
  else
    if config.height then
      local total = vim.o.lines - vim.o.cmdheight - 1
      return math.max(8, math.min(tonumber(config.height) or 20, total - 2)), "h"
    elseif config.split_ratio then
      local total = vim.o.lines - vim.o.cmdheight - 1
      local h = math.floor(total * config.split_ratio)
      return math.max(8, math.min(h, total - 2)), "h"
    end
  end
  return nil, nil
end

--- Centered float that takes ~90% of the screen. The `split` config no longer
--- influences float placement — it's used only for real splits.
--- @return { row: integer, col: integer, width: integer, height: integer }
local function get_float_geometry()
  local cols = vim.o.columns
  local lines_avail = math.max(1, vim.o.lines - vim.o.cmdheight - 1)
  local ratio = config.float_ratio or 0.9
  local w = math.max(40, math.min(math.floor(cols * ratio), cols - 2))
  local h = math.max(10, math.min(math.floor(lines_avail * ratio), lines_avail - 1))
  local col = math.max(0, math.floor((cols - w) / 2))
  local row = math.max(0, math.floor((lines_avail - h) / 2))
  return { row = row, col = col, width = w, height = h }
end

local function apply_split_size()
  local dim, axis = get_target_split_dims()
  if not dim then
    return
  end
  if axis == "w" then
    vim.cmd("vertical resize " .. dim)
  else
    vim.cmd("resize " .. dim)
  end
end

local function apply_agent_scrollback(buf)
  local n = config.scrollback
  if type(n) == "number" and n >= 1 and n <= 100000 and vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].scrollback = n
  end
end

local function lock_cursor_window(win)
  if config.window_mode == "float" or not config.lock_split then
    return
  end
  win = win or vim.api.nvim_get_current_win()
  if config.split == "vertical" then
    vim.wo[win].winfixwidth = true
    vim.wo[win].winfixheight = false
  else
    vim.wo[win].winfixheight = true
    vim.wo[win].winfixwidth = false
  end
end

local function valid_job_id(job)
  return type(job) == "number" and job > 0
end

local function term_buffer_alive(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if vim.bo[bufnr].buftype ~= "terminal" then
    return false
  end
  local ok, job = pcall(vim.fn.getbufvar, bufnr, "terminal_job_id")
  return ok and valid_job_id(job)
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
  local g = get_float_geometry()
  local cfg = {
    relative = "editor",
    row = g.row,
    col = g.col,
    width = g.width,
    height = g.height,
  }
  vim.api.nvim_win_set_config(win, cfg)
  state.float_geometry = cfg
end

--- After outer resize: re-apply ratio only if the agent window size drifted; always refresh winfix*.
local function sync_agent_split_after_resize()
  if not config.lock_split then
    return
  end
  local cur = current_bufnr()
  if not cur or not term_buffer_alive(cur) then
    return
  end
  local win = win_for_buf(cur)
  if not win then
    return
  end
  local target, axis = get_target_split_dims()
  if not target then
    return
  end
  local cur_dim = axis == "w" and vim.api.nvim_win_get_width(win) or vim.api.nvim_win_get_height(win)
  local saved = vim.api.nvim_get_current_win()
  if cur_dim ~= target and vim.api.nvim_win_is_valid(saved) then
    vim.api.nvim_set_current_win(win)
    apply_split_size()
    if vim.api.nvim_win_is_valid(saved) then
      vim.api.nvim_set_current_win(saved)
    end
  end
  if vim.api.nvim_win_is_valid(win) then
    lock_cursor_window(win)
  end
end

local function sync_agent_after_resize()
  if config.window_mode == "float" then
    sync_float_after_resize()
  else
    sync_agent_split_after_resize()
  end
end

local function schedule_resize_sync()
  local ms = config.resize_debounce_ms
  if not ms or ms <= 0 then
    return
  end
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
    vim.schedule(sync_agent_after_resize)
  end)
end

--- While the outer frame is resized, snap the float back to the last applied size so the PTY does not
--- get a SIGWINCH per drag step; debounced sync_agent_after_resize applies the final size once idle.
local function on_vim_resized()
  if config.window_mode == "float" and state.float_geometry then
    local cur = current_bufnr()
    if cur then
      local win = win_for_buf(cur)
      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_config(win, state.float_geometry)
      end
    end
  end
  schedule_resize_sync()
end

--- Bind <C-h/j/k/l> inside the agent's float buffer to close the float. One
--- muscle-memory "move window" stroke dismisses the overlay. No-op in split
--- mode — those are useful window-nav keys when the agent is a real split.
local function set_float_close_keymaps(bufnr)
  if config.window_mode ~= "float" then return end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local opts = { buffer = bufnr, noremap = true, silent = true, nowait = true }
  local function close_float()
    local cur = current_bufnr()
    if not cur then return end
    local w = win_for_buf(cur)
    if w and vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_close, w, false)
    end
  end
  for _, key in ipairs({ "<C-h>", "<C-j>", "<C-k>", "<C-l>" }) do
    -- Terminal mode: leave the PTY first, then close on the next tick so the
    -- mode switch finishes before we rip the window out.
    vim.keymap.set("t", key, function()
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true),
        "n", false
      )
      vim.schedule(close_float)
    end, opts)
    vim.keymap.set("n", key, close_float, opts)
  end
end

local function attach_term_close(buf)
  local ag = vim.api.nvim_create_augroup(profile.augroup_prefix .. "TermClose_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("TermClose", {
    group = ag,
    buffer = buf,
    once = true,
    callback = function()
      clear_bufnr_for_buf(buf)
    end,
  })
end

--- After <leader>rc, reconnect to any surviving agent terminal buffers.
local function restore_agent_bufnr()
  local stored = vim.g[G_BUFNR]
  state.bufnrs = {}
  if type(stored) == "table" then
    for cwd, nr in pairs(stored) do
      if type(cwd) == "string" and type(nr) == "number" and term_buffer_alive(nr) then
        state.bufnrs[cwd] = nr
        pcall(function() vim.b[nr].luanphan_persist_term = true end)
        attach_term_close(nr)
        apply_agent_scrollback(nr)
        set_float_close_keymaps(nr)
      end
    end
  end
  persist_map()
  local cur = current_bufnr()
  if cur then
    local rwin = win_for_buf(cur)
    if rwin then
      lock_cursor_window(rwin)
    end
  end
end

local function open_terminal_split()
  if config.split == "vertical" then
    vsplit_right()
  else
    vim.cmd("split")
  end
  vim.cmd("enew")
  apply_split_size()
  lock_cursor_window()
  local buf = vim.api.nvim_get_current_buf()
  local cwd = cwd_key()
  vim.fn.termopen(argv_for_termopen(), { cwd = cwd })
  apply_agent_scrollback(buf)
  set_agent_bufnr(buf, cwd)
  attach_term_close(buf)
  vim.defer_fn(function()
    vim.cmd("startinsert")
  end, 10)
end

local function open_terminal_float()
  local buf = vim.api.nvim_create_buf(false, true)
  local g = get_float_geometry()
  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = g.row,
    col = g.col,
    width = g.width,
    height = g.height,
    style = "minimal",
    border = config.float_border or "single",
  })
  state.float_geometry = {
    relative = "editor",
    row = g.row,
    col = g.col,
    width = g.width,
    height = g.height,
  }
  local cwd = cwd_key()
  vim.fn.termopen(argv_for_termopen(), { cwd = cwd })
  apply_agent_scrollback(buf)
  set_agent_bufnr(buf, cwd)
  attach_term_close(buf)
  set_float_close_keymaps(buf)
  vim.defer_fn(function()
    vim.cmd("startinsert")
  end, 10)
end

local function open_terminal()
  if config.window_mode == "float" then
    open_terminal_float()
  else
    open_terminal_split()
  end
end

local function show_terminal_split()
  local cur = current_bufnr()
  if not cur then return end
  if config.split == "vertical" then
    vsplit_right()
  else
    vim.cmd("split")
  end
  vim.api.nvim_win_set_buf(0, cur)
  apply_agent_scrollback(cur)
  apply_split_size()
  lock_cursor_window()
  vim.defer_fn(function()
    vim.cmd("startinsert")
  end, 10)
end

local function show_terminal_float()
  local cur = current_bufnr()
  if not cur then return end
  local g = get_float_geometry()
  vim.api.nvim_open_win(cur, true, {
    relative = "editor",
    row = g.row,
    col = g.col,
    width = g.width,
    height = g.height,
    style = "minimal",
    border = config.float_border or "single",
  })
  state.float_geometry = {
    relative = "editor",
    row = g.row,
    col = g.col,
    width = g.width,
    height = g.height,
  }
  apply_agent_scrollback(cur)
  set_float_close_keymaps(cur)
  vim.defer_fn(function()
    vim.cmd("startinsert")
  end, 10)
end

local function show_terminal()
  if config.window_mode == "float" then
    show_terminal_float()
  else
    show_terminal_split()
  end
end

local API = {}

function API.toggle()
  local cur = current_bufnr()
  if cur and term_buffer_alive(cur) then
    local win = win_for_buf(cur)
    if win then
      vim.api.nvim_win_close(win, false)
      return
    end
    show_terminal()
    return
  end
  -- Stale or missing entry for this cwd; open a fresh one.
  set_agent_bufnr(nil)
  open_terminal()
end

--- Jump to the agent terminal (float or split) for the current cwd. If the buffer is hidden, shows it again.
function API.focus()
  local cur = current_bufnr()
  if not cur or not term_buffer_alive(cur) then
    nx("no agent terminal — use " .. profile.hint_open .. " to open", vim.log.levels.INFO)
    return
  end
  local win = win_for_buf(cur)
  if not win then
    show_terminal()
    return
  end
  vim.api.nvim_set_current_win(win)
  vim.defer_fn(function()
    vim.cmd("startinsert")
  end, 10)
end

local function get_job_id(bufnr)
  local ok, job = pcall(vim.fn.getbufvar, bufnr, "terminal_job_id")
  if not ok or not valid_job_id(job) then
    return nil
  end
  return job
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
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
end

function API.send_selection()
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

  local function focus_term_win()
    local cur = current_bufnr()
    if not cur then return end
    local w = win_for_buf(cur)
    if w then
      vim.api.nvim_set_current_win(w)
      vim.cmd("startinsert")
    end
  end

  local function deliver(attempt)
    attempt = attempt or 1
    local cur = current_bufnr()
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
      show_terminal()
    end

    local job = get_job_id(cur)
    if not job and attempt < 3 then
      vim.defer_fn(function()
        deliver(attempt + 1)
      end, config.defer_send_ms)
      return
    end
    if not job then
      nx("no terminal job", vim.log.levels.ERROR)
      return
    end

    local ok, err = pcall(vim.fn.chansend, job, payload)
    if not ok then
      nx("send failed: " .. tostring(err), vim.log.levels.ERROR)
      set_agent_bufnr(nil)
      return
    end

    focus_term_win()
  end

  local cur = current_bufnr()
  if not cur or not term_buffer_alive(cur) then
    set_agent_bufnr(nil)
    open_terminal()
    vim.defer_fn(function()
      deliver(1)
    end, config.defer_send_ms)
    return
  end

  deliver(1)
end

function API.setup(opts)
  config = merge(vim.deepcopy(DEFAULTS), opts or {})
  if config.window_mode == "float" and (not config.resize_debounce_ms or config.resize_debounce_ms <= 0) then
    config.resize_debounce_ms = 250
  end
  restore_agent_bufnr()

  local resize_ok = config.resize_debounce_ms and config.resize_debounce_ms > 0
  local want_resize = resize_ok and (config.window_mode == "float" or config.lock_split)
  if want_resize then
    vim.api.nvim_create_autocmd("VimResized", {
      group = vim.api.nvim_create_augroup(profile.augroup_prefix .. "Resize", { clear = true }),
      callback = on_vim_resized,
    })
  end

  -- Per-worktree visibility: remember whether the agent was visible in the old cwd;
  -- auto-restore when returning to a cwd where it was visible last.
  vim.api.nvim_create_autocmd("DirChangedPre", {
    group = vim.api.nvim_create_augroup(profile.augroup_prefix .. "DirPre", { clear = true }),
    callback = function()
      local old = cwd_key()
      local cur = state.bufnrs[old]
      if not cur or not term_buffer_alive(cur) then
        state.visibility[old] = false
        return
      end
      local win = win_for_buf(cur)
      if win then
        state.visibility[old] = true
        pcall(vim.api.nvim_win_close, win, false)
      else
        state.visibility[old] = false
      end
    end,
  })

  vim.api.nvim_create_autocmd("DirChanged", {
    group = vim.api.nvim_create_augroup(profile.augroup_prefix .. "Dir", { clear = true }),
    callback = function()
      local new = cwd_key()
      if not state.visibility[new] then return end
      local cur = state.bufnrs[new]
      if not cur or not term_buffer_alive(cur) then return end
      if win_for_buf(cur) then return end
      show_terminal()
    end,
  })

  local km = profile.keymaps
  local md = profile.map_desc or {}
  vim.keymap.set("n", km.toggle, function()
    API.toggle()
  end, { desc = md.toggle or "Toggle agent terminal" })

  if km.focus then
    vim.keymap.set("n", km.focus, function()
      API.focus()
    end, { desc = md.focus or "Focus agent terminal" })
  end

  vim.keymap.set("x", km.send, function()
    API.send_selection()
  end, { desc = md.send or "Send selection to agent" })
end

  return API
end

return M
