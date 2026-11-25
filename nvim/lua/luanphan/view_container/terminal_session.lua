local M = {}
local view_container = require("luanphan.view_container")
local terminal_pane = require("luanphan.view_container.terminal")

function M.create(profile)
  local backend, config, nx = profile.backend, profile.config, profile.notify
  local augroup_name = profile.augroup
  local container = profile.container

  local function win_for_buf(bufnr)
    return vim.fn.win_findbuf(bufnr)[1]
  end

  local function show(buf, win)
    local cwd = profile.cwd(buf) or container:context()
    profile.on_show(buf, cwd)
    container:present_tile(cwd, { id = buf, bufnr = buf }, win)
  end

  local function resume_terminal_view(win, buf, opts)
    profile.mark_used(buf)
    pcall(show, buf, win)
    terminal_pane.focus_input(win, buf, opts and opts.view_mode)
  end

  local function apply_scrollback(buf)
    local n = config.scrollback
    if type(n) == "number" and n >= 1 and n <= 100000 and vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].scrollback = n
    end
  end

  local function quit_action(buf)
    local cwd = profile.cwd(buf)
    if not cwd then return end
    local next_tab = container:replacement(cwd, buf)
    return function() container:focus_replacement(next_tab) end
  end

  local function notify_close(buf)
    local cwd = profile.cwd(buf)
    local ok, cleanup = pcall(profile.on_close, buf, cwd)
    if ok then container:remove_tab(buf, cwd, cleanup) end
  end

  local function register_terminal(buf, cwd, launched)
    terminal_pane.configure_buffer(buf)
    container:bind_title(buf)
    profile.on_register(buf, launched)
    container:invalidate_sidebar()
    apply_scrollback(buf)
    terminal_pane.set_reference_cwd(buf, cwd)
    local group = vim.api.nvim_create_augroup(augroup_name .. "_Window_" .. buf, { clear = true })
    terminal_pane.bind_process(buf, group, backend, notify_close, quit_action)
    container:bind_terminal(buf, cwd)
    if not profile.shell then
      vim.keymap.set("t", "<C-l>", "<Nop>", { buffer = buf, silent = true, nowait = true })
    end
  end

  local function start_terminal(buf, cwd, opts)
    local win = win_for_buf(buf)
    local geometry = not win and container.opts.layout().body
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
    local function open(initial)
      local layout = container.opts.layout()
      local win = container:open_float(layout, initial, true)
      container:layout_sidebar(win, layout)
      return win
    end
    return terminal_pane.mount(buf, opts and opts.reuse_win, open, function(win) container:reserve(win) end,
      container.opts.highlights)
  end

  local function open_terminal(opts, on_start)
    local buf = vim.api.nvim_create_buf(false, true)
    local win = mount_terminal(buf, container:reuse(nil, opts))
    local cwd = container:context()
    if not start_terminal(buf, cwd, opts) then return end
    if on_start then on_start(buf) end
    resume_terminal_view(win, buf, opts)
    return buf
  end

  local function show_terminal(bufnr, opts)
    local win = mount_terminal(bufnr, opts)
    apply_scrollback(bufnr)
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

  function API.focus(bufnr, opts, reopen)
    local cur = bufnr or profile.current()
    if not cur or not backend.running(cur) then
      nx("no terminal — use " .. profile.hint_open .. " to open", vim.log.levels.INFO)
      return false
    end
    if not container:visible_window(profile.cwd(cur), cur) then
      if reopen then container:hide() else opts = container:reuse(cur, opts) end
    end
    local win = win_for_buf(cur)
    if not win then
      show_terminal(cur, opts)
      return true
    end
    terminal_pane.configure_window(win, container.opts.highlights)
    vim.api.nvim_set_current_win(win)
    resume_terminal_view(win, cur, opts)
    return true
  end

  function API.paste(payload, target, opts)
    local function destination()
      return terminal_pane.running(target) and target or profile.current()
    end
    local function deliver(attempt)
      local buf = destination()
      if not terminal_pane.running(buf) then
        if attempt == 3 then return nx("terminal not ready", vim.log.levels.ERROR) end
        return vim.defer_fn(function() deliver(attempt + 1) end, config.defer_send_ms or 200)
      end
      if not win_for_buf(buf) then API.focus(buf, opts) end
      if not terminal_pane.send(buf, "\27[200~" .. payload .. "\27[201~") then
        return nx("could not send to the terminal", vim.log.levels.ERROR)
      end
      local win = win_for_buf(buf)
      if win then
        vim.api.nvim_set_current_win(win)
        vim.cmd.startinsert()
      end
    end
    if terminal_pane.running(destination()) then return deliver(1) end
    target = API.new(opts)
    vim.defer_fn(function() deliver(1) end, config.defer_send_ms or 200)
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
      container:use_anchor(view_container.group_anchor(win))
      container:reserve(win)
      terminal_pane.configure_window(win, container.opts.highlights)
      pcall(show, cur, win)
    end
  end

  return API
end

return M
