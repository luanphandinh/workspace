local api, uv = vim.api, vim.uv
local pty = require("luanphan.view_container.tmux.pane")
local client = require("luanphan.view_container.tmux.client")

local M = {}

function M.create(opts)
  local server = client.new(opts.server)
  local state = opts.state or { groups = {}, buffers = {} }
  local backend = { state = state }
  local metadata = opts.metadata
  local pane_order = "@luanphan-pane-order"
  local pending_order, order_timer = {}, nil
  local history_limit = 10000
  local pane_format = "#{session_id}\t#{session_name}\t#{window_id}\t#{pane_id}\t#{pane_width}\t#{pane_height}\t#{" .. metadata .. "}"
    .. "\t#{" .. pane_order .. "}"
  local launch = [[
  trap 'rm -- "$2"' EXIT
  tmux wait-for "$1" || exit
  . "$2" || exit
  rm -- "$2"
  trap - EXIT
  shift 2
  exec "$@"
  ]]

  local function run(args)
    local result = server:run(args)
    if result.code == 0 then return vim.trim(result.stdout or "") end
    return nil, vim.trim(result.stderr or "")
  end

  function backend.load_window_order()
    return server:load_window_order()
  end

  function backend.save_window_order(order)
    return server:save_window_order(nil, order)
  end

  local function flush_pane_order()
    if order_timer then vim.fn.timer_stop(order_timer) end
    order_timer = nil
    local args = {}
    for buf, position in pairs(pending_order) do
      local pane = state.buffers[buf]
      if pane then
        if #args > 0 then args[#args + 1] = ";" end
        vim.list_extend(args, { "set-option", "-p", "-t", pane.id, pane_order, tostring(position) })
      end
    end
    pending_order = {}
    if #args > 0 then run(args) end
  end

  function backend.queue_pane_order(buf, position)
    pending_order[buf] = position
    if order_timer then vim.fn.timer_stop(order_timer) end
    order_timer = vim.fn.timer_start(250, flush_pane_order)
  end

  local function launch_file()
    local lines = { "unset TMUX TMUX_PANE TERM_PROGRAM TERM_PROGRAM_VERSION VIM VIMRUNTIME", "export TERM=xterm-256color" }
    local env = vim.fn.environ()
    env.TMUX, env.TMUX_PANE, env.TERM, env.PWD, env.SHLVL, env._ = nil, nil, nil, nil, nil, nil
    env.VIM, env.VIMRUNTIME = nil, nil
    if env.TERM_PROGRAM == "tmux" then
      env.TERM_PROGRAM, env.TERM_PROGRAM_VERSION = nil, nil
    end
    if vim.o.termguicolors then
      env.NO_COLOR, env.COLORTERM = nil, "truecolor"
      lines[#lines + 1] = "unset NO_COLOR"
    end
    for name, value in pairs(env) do
      if name:match("^[%a_][%w_]*$") then
        lines[#lines + 1] = "export " .. name .. "=" .. vim.fn.shellescape(value)
      end
    end
    local path = vim.fn.tempname()
    local fd, err = uv.fs_open(path, "wx", 384)
    if not fd then return nil, err end
    local written, write_err = uv.fs_write(fd, table.concat(lines, "\n") .. "\n")
    uv.fs_close(fd)
    if written then return path end
    uv.fs_unlink(path)
    return nil, write_err
  end

  local function window_title(title)
    return (title:gsub("[%c]", " "):gsub("#", "##"))
  end

  local function records(session)
    local args = { "list-panes", session and "-s" or "-a", "-F", pane_format }
    if session then vim.list_extend(args, { "-t", session }) end
    local output = run(args)
    if not output then return nil end
    local result = {}
    for line in output:gmatch("[^\n]+") do
      local fields = vim.split(line, "\t", { plain = true })
      local ok, data = pcall(vim.json.decode, fields[7] or "")
      if ok and type(data) == "table" and type(data.cwd) == "string" and type(data.workspace) == "string"
        and opts.valid(data) then
        result[#result + 1] = {
          session = fields[1], session_name = fields[2], window = fields[3], id = fields[4],
          width = tonumber(fields[5]), height = tonumber(fields[6]), data = data, pane_order = tonumber(fields[8]),
        }
      end
    end
    return result
  end

  local function finish(pane, lost)
    local buf = pane.bufnr
    if pane.group.panes[pane.id] ~= pane then return end
    pane.group.panes[pane.id], state.buffers[buf], pane.client = nil, nil, nil
    state.pane_index = nil
    if api.nvim_buf_is_valid(buf) and not state.leaving then
      opts.on_exit(buf, lost)
      if pane.on_exit then pane.on_exit() end
    end
  end

  local function forget_group(group)
    if state.groups[group.workspace] == group then state.groups[group.workspace] = nil end
  end

  local function start(pane)
    local gate = pane.data.gate
    if not gate then return end
    pane.client:request({ "wait-for", "-S", gate }, function(ok)
      if not ok then return end
      pane.data.gate = nil
      if pane.client and pane.client.job then
        pane.client:request({ "set-option", "-p", "-t", pane.id, metadata, vim.json.encode(pane.data) })
      end
    end)
  end

  local connect
  connect = function(group)
    local client = server:attach({ id = group.id }, {
      flags = "ignore-size",
      ready = function()
        for _, pane in pairs(group.panes) do
          if pane.data.gate then start(pane) else pty.paint(pane) end
        end
      end,
      output = function(id, bytes)
        pty.receive(group.panes[id], bytes)
      end,
      event = function(name, payload)
        if name ~= "window-close" and name ~= "unlinked-window-close" then return end
        for _, pane in pairs(group.panes) do
          if pane.window == payload then finish(pane, false) return end
        end
      end,
      exit = function()
        group.client = nil
        if state.leaving then return end
        local current = records(group.id)
        local healthy = current or run({ "show-options", "-sv", "exit-empty" })
        local remaining = {}
        for _, record in ipairs(current or {}) do remaining[record.id] = true end
        for _, pane in pairs(group.panes) do
          pane.client, pane.ready, pane.capturing = nil, false, false
          if not remaining[pane.id] then finish(pane, not healthy) end
        end
        if next(group.panes) then connect(group) else forget_group(group) end
      end,
    })
    group.client = client
    for _, pane in pairs(group.panes) do pane.client = client end
    return client
  end

  local function attach(buf, record, new)
    local group = state.groups[record.data.workspace]
    if not group then
      group = { id = record.session, name = record.session_name, workspace = record.data.workspace, panes = {} }
      state.groups[group.workspace] = group
    end
    record.group, record.bufnr = group, buf
    record.process = backend
    record.replay_osc = opts.replay_osc
    record.history_limit, record.restore_primary = history_limit, true
    record.client, record.ready = group.client, new or record.data.gate ~= nil
    record.view_width, record.view_height = record.width, record.height
    group.panes[record.id], state.buffers[buf] = record, record
    state.pane_index = nil
    vim.b[buf].luanphan_persist_term = true
    opts.on_attach(buf, record)
    local win
    if vim.fn.bufwinid(buf) == -1 then
      win = api.nvim_open_win(buf, false, {
        relative = "editor", row = 0, col = 0, width = record.width, height = record.height,
        hide = true, style = "minimal", noautocmd = true,
      })
    end
    pty.open(record)
    if win then api.nvim_win_close(win, true) end

    if not group.client then
      if not connect(group) then
        finish(record, true)
        return false
      end
    elseif group.client.ready then
      if record.data.gate then start(record) else pty.paint(record) end
    end
    return true
  end

  function backend.launch(buf, command, data, width, height, position)
    local path, err = launch_file()
    if not path then return false, err end
    local gate = "pane-" .. vim.fn.sha256(path):sub(1, 16)
    data.gate = gate
    local group = state.groups[data.workspace]
    if group and not next(group.panes) and not run({ "has-session", "-t", group.id }) then
      forget_group(group)
      group = nil
    end
    local name = group and group.name or vim.fs.basename(data.workspace):gsub("[:.%c]", "_")
    if name == "" then name = "workspace" end
    if not group and run({ "has-session", "-t", "=" .. name }) then
      name = name .. "-" .. vim.fn.sha256(data.workspace):sub(1, 12)
    end
    local args = group and { "new-window", "-d", "-t", group.id .. ":" } or {
      "start-server", ";", "set-option", "-s", "exit-empty", "off",
      ";", "set-option", "-g", "history-limit", tostring(history_limit),
      ";", "new-session", "-d", "-s", name, "-x", tostring(width), "-y", tostring(height),
    }
    vim.list_extend(args, {
      "-c", data.cwd, "-n", gate, "-P", "-F", "#{session_id}\t#{window_id}\t#{pane_id}",
      "sh", "-c", launch, "sh", gate, path,
    })
    vim.list_extend(args, command)
    local target = name .. ":" .. gate
    vim.list_extend(args, {
      ";", "resize-window", "-t", target, "-x", tostring(width), "-y", tostring(height),
      ";", "set-option", "-p", "-t", target, metadata, vim.json.encode(data),
    })
    if position then
      vim.list_extend(args, { ";", "set-option", "-p", "-t", target, pane_order, tostring(position) })
    end
    vim.list_extend(args, { ";", "rename-window", "-t", target, "--", window_title(data.label) })
    local output, error_message = run(args)
    local session_id, window, id = (output or ""):match("^(%$%d+)\t(@%d+)\t(%%%d+)$")
    if not id then
      run({ "kill-window", "-t", target })
      uv.fs_unlink(path)
      return false, error_message or output
    end
    return attach(buf, { session = session_id, session_name = name, window = window,
      id = id, width = width, height = height, data = data }, true)
  end

  function backend.restore(callback)
    local endpoint = opts.server()
    endpoint = endpoint.socket or endpoint.name
    if state.restored == endpoint then return end
    state.restored = endpoint
    for _, record in ipairs(records() or {}) do
      callback(record)
    end
  end

  function backend.adopt(buf, record)
    if record.data.title then vim.b[buf].term_title = record.data.title end
    return attach(buf, record, false)
  end

  function backend.running(buf)
    local pane = state.buffers[buf]
    return pane ~= nil and pane.group.panes[pane.id] == pane
  end

  function backend.panes(kind, cwd)
    local index = state.pane_index
    if not index then
      index = { all = {}, by_cwd = {} }
      for _, pane in pairs(state.buffers) do index.all[#index.all + 1] = pane end
      table.sort(index.all, function(a, b) return a.bufnr < b.bufnr end)
      for _, pane in ipairs(index.all) do
        local path = pane.data.cwd
        local group = index.by_cwd[path] or {}
        index.by_cwd[path] = group
        group[#group + 1] = pane
      end
      state.pane_index = index
    end
    local candidates = index.all
    if cwd then candidates = index.by_cwd[cwd] or {} end
    local panes = {}
    for _, pane in ipairs(candidates) do
      local buf = pane.bufnr
      if (not kind or pane.data[opts.kind] == kind) and api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "terminal" then
        panes[#panes + 1] = pane
      end
    end
    return panes
  end

  function backend.on_exit(buf, callback)
    local pane = state.buffers[buf]
    if not pane then return false end
    pane.on_exit = callback
    return true
  end

  function backend.focus(buf)
    local pane = state.buffers[buf]
    if not pane or not pane.client or pane.group.active == pane.window then return end
    pane.group.active = pane.window
    pane.client:request({ "select-window", "-t", pane.window })
  end

  function backend.stop(buf)
    local pane = state.buffers[buf]
    if not pane then return false end
    local result = run({ "kill-pane", "-t", pane.id })
    if not result then return false end
    finish(pane, false)
    return true
  end

  function backend.update(buf, changes)
    local pane = state.buffers[buf]
    if not pane or not pane.client or not pane.client.job then return end
    local old_label = pane.data.label
    local updated = vim.tbl_extend("force", pane.data, changes)
    if vim.deep_equal(updated, pane.data) then return end
    if updated.cwd ~= pane.data.cwd then state.pane_index = nil end
    pane.data = updated
    local commands = { { "set-option", "-p", "-t", pane.id, metadata, vim.json.encode(updated) } }
    if old_label ~= updated.label then
      commands[#commands + 1] = { "rename-window", "-t", pane.window, "--", window_title(updated.label) }
    end
    pane.client:request_batch(commands)
  end

  api.nvim_create_autocmd("VimLeavePre", {
    group = api.nvim_create_augroup(opts.augroup, { clear = true }),
    callback = function()
      state.leaving = true
      flush_pane_order()
      for _, group in pairs(state.groups) do
        if group.client then group.client:detach() end
      end
    end,
  })

  for _, pane in pairs(state.buffers) do
    pane.process, pane.replay_osc = backend, opts.replay_osc
  end

  return backend
end

return M
