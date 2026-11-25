local M = {}
local view_container = require("luanphan.view_container")
local terminal_pane = require("luanphan.view_container.terminal")

function M.create(profile)
  local backend, config, nx = profile.backend, profile.config, profile.notify
  local augroup_name = profile.augroup

  local function cwd_key()
    return vim.fn.getcwd()
  end

  local function win_for_buf(bufnr)
    return vim.fn.win_findbuf(bufnr)[1]
  end

  local function resume_terminal_view(win, bufnr, opts)
    profile.mark_used(bufnr)
    pcall(profile.on_show, bufnr, win, profile.cwd(bufnr) or cwd_key())
    terminal_pane.focus_input(win, bufnr, opts and opts.view_mode)
  end

  local function get_float_layout()
    return view_container.layout(profile.settings(), {
      border = config.float_border or "single", zindex = config.float_zindex, min_height = 12,
    })
  end

  local function open_float(bufnr)
    local layout = get_float_layout()
    local win = view_container.open_float(layout, bufnr, true)
    profile.on_float_layout(win, layout, true)
    return win
  end

  local function apply_scrollback(buf)
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
    if terminal_pane.is_closing_tile(win) then return end
    profile.on_float_layout(win, get_float_layout())
  end

  local function bind_terminal(buf)
    terminal_pane.bind_navigation(buf, profile.on_navigate)
    if not profile.shell then
      vim.keymap.set("t", "<C-l>", "<Nop>", { buffer = buf, silent = true, nowait = true })
    end
  end

  local function quit_action(buf)
    local cwd = profile.cwd(buf)
    if cwd and profile.on_quit then
      local ok, action = pcall(profile.on_quit, buf, cwd)
      if ok and type(action) == "function" then return action end
    end
  end

  local function notify_close(buf)
    if profile.on_close then
      pcall(profile.on_close, buf, profile.cwd(buf))
    end
  end

  local function register_terminal(buf, cwd, launched)
    terminal_pane.configure_buffer(buf)
    profile.on_register(buf, launched)
    apply_scrollback(buf)
    terminal_pane.set_reference_cwd(buf, cwd)
    local group = vim.api.nvim_create_augroup(augroup_name .. "_Window_" .. buf, { clear = true })
    terminal_pane.bind_process(buf, group, backend, notify_close, quit_action)
    bind_terminal(buf)
  end

  local function start_terminal(buf, cwd, opts)
    local win = win_for_buf(buf)
    local geometry = not win and get_float_layout().body
    local width = win and vim.api.nvim_win_get_width(win) or geometry.width
    local height = win and vim.api.nvim_win_get_height(win) or geometry.height
    local command, data = profile.command(buf, cwd, opts)
    local ok, err = backend.launch(buf, command, data, width, math.max(1, height - 1))
    if not ok then
      nx("could not launch tmux pane: " .. (err or "attach failed"), vim.log.levels.ERROR)
      vim.api.nvim_buf_delete(buf, { force = true })
      return false
    end
    register_terminal(buf, cwd, true)
    return true
  end

  local function mount_terminal(buf, opts)
    view_container.show_panel(profile.panel)
    return terminal_pane.mount(buf, opts and opts.reuse_win, open_float, prepare_terminal_window,
      profile.highlights, config.float_zindex)
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
    local win = mount_terminal(bufnr, opts)
    apply_scrollback(bufnr)
    bind_terminal(bufnr)
    resume_terminal_view(win, bufnr, opts)
  end

  local API = {}

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
    profile.on_adopt(buf, data)
    if not backend.adopt(buf, record) then
      vim.api.nvim_buf_delete(buf, { force = true })
      return
    end
    register_terminal(buf, data.cwd)
    return buf
  end

  function API.focus(bufnr, opts)
    local cur = bufnr or profile.current()
    if not cur or not backend.running(cur) then
      nx("no terminal — use " .. profile.hint_open .. " to open", vim.log.levels.INFO)
      return false
    end
    local win = win_for_buf(cur)
    if not win then
      show_terminal(cur, opts)
      return true
    end
    terminal_pane.configure_window(win, profile.highlights)
    vim.api.nvim_set_current_win(win)
    resume_terminal_view(win, cur, opts)
    return true
  end

  function API.layout(win)
    layout_float(win)
  end

  function API.prepare_tile(win, opened)
    if opened then terminal_pane.configure_window(win, profile.highlights) end
  end

  function API.setup()
    -- Rebind surviving panes after a config reload.
    for _, pane in ipairs(profile.panes()) do
      register_terminal(pane.bufnr, pane.data.cwd)
    end
    local cur = profile.current()
    local win = cur and win_for_buf(cur)
    if win then
      view_container.show_panel(profile.panel)
      prepare_terminal_window(win)
      terminal_pane.configure_window(win, profile.highlights)
      pcall(profile.on_show, cur, win, profile.cwd(cur))
    end
  end

  return API
end

return M
