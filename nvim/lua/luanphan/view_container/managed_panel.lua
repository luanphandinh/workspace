-- Live panes survive UI restarts. Saved records can also reopen a pane after its server exits.
local window = require("luanphan.view_container.window")
local M = {}

function M.create(container, opts)
  local backend, providers = container.opts.panes.backend, opts.providers
  local panel, apis, restored = {}, {}, {}
  local fields = opts.fields

  function panel.visible()
    local win = container:content_window()
    if not win then return end
    local buf = vim.api.nvim_win_get_buf(win)
    local kind = container.opts.panes.kind(buf)
    if providers[kind] then return { kind = kind, bufnr = buf } end
  end

  function panel.recent_tab(context, accept)
    local recent
    for _, tab in ipairs(container:pane_tabs(context)) do
      if (not accept or accept(tab.kind)) and (not recent or tab.last_used > recent.last_used) then recent = tab end
    end
    return recent
  end

  local function restore_ui(flag)
    if vim.g[flag] or vim.v.vim_did_enter == 0 or #vim.api.nvim_list_uis() == 0 then return end
    vim.g[flag] = true
    panel.reopen(true)
  end

  function panel.watch(group, startup_flag)
    vim.api.nvim_create_autocmd({ "VimEnter", "UIEnter" }, {
      group = group, callback = function() vim.schedule(function() restore_ui(startup_flag) end) end,
    })
    window.track_directory(group, function(cwd)
      local pane = panel.visible()
      if pane and container.layout_context == cwd then return pane end
    end, function() container:hide() end, function(cwd, pane)
      if panel.visible() then return end
      local buf = backend.running(pane.bufnr) and pane.bufnr or container:recent_pane(cwd, pane.kind)
      if buf then opts.owner.open(pane.kind, buf) end
    end)
  end

  function panel.provider(kind)
    if not apis[kind] then
      local api = opts.create(kind)
      apis[kind] = api
      local ok, err = xpcall(api.setup, debug.traceback)
      if not ok then
        apis[kind] = nil
        error(err, 0)
      end
    end
    return apis[kind]
  end

  local function next_use()
    local sequence = (tonumber(vim.g[fields.sequence]) or 0) + 1
    vim.g[fields.sequence] = sequence
    return sequence
  end

  function panel.show(buf, cwd)
    backend.focus(buf)
    local seconds, micros = vim.uv.gettimeofday()
    vim.b[buf][fields.used_at] = seconds + micros / 1000000
    opts.remember(buf)
    if restored[cwd] then return end
    restored[cwd] = true
    local path = vim.uv.fs_realpath(cwd) or cwd
    for _, kind in ipairs(container.opts.panes.kinds) do
      if providers[kind].restore_on_open then
        local live = {}
        for _, pane in ipairs(container:panes(cwd, kind)) do
          local id = vim.b[pane.bufnr][fields.buffer_id]
          if id then live[id] = true end
        end
        local saved = opts.list(kind)
        table.sort(saved, function(a, b)
          if a.last_used ~= b.last_used then return a.last_used < b.last_used end
          return a[fields.id] < b[fields.id]
        end)
        for _, record in ipairs(saved) do
          if record.path == path and not live[record[fields.id]] then
            panel.provider(kind).start_hidden(cwd, opts.resume_options(record))
          end
        end
      end
    end
  end

  function panel.mark_used(buf)
    vim.b[buf][fields.used] = next_use()
  end

  function panel.close(buf, cwd)
    if vim.b[buf][fields.lost] then
      restored[cwd] = nil
    elseif type(vim.v.exiting) ~= "number" then
      return opts.discard(buf)
    end
  end

  function panel.restore_running()
    local running = {}
    backend.restore(function(record)
      if providers[record.data[fields.kind]] and vim.fn.isdirectory(record.data.cwd) == 1 then
        running[#running + 1] = record
      end
    end)
    if #running == 0 then return end
    local saved = {}
    for _, record in ipairs(opts.list()) do saved[opts.key(record)] = record end
    for _, record in ipairs(running) do
      local data = record.data
      record.saved = data[fields.id] and saved[opts.key(data)]
      data.used_at = math.max(data.used_at or 0, record.saved and record.saved.last_used or 0)
    end
    table.sort(running, function(a, b)
      if a.data.used_at ~= b.data.used_at then return a.data.used_at < b.data.used_at end
      return (a.data.used or 0) < (b.data.used or 0)
    end)
    for _, record in ipairs(running) do
      local data, saved_pane = record.data, record.saved
      record.saved = nil
      if data.used_at > 0 or (data.used or 0) > 0 then data.used = next_use() end
      local buf = panel.provider(data[fields.kind]).adopt(record, saved_pane)
      if buf then opts.adopted(buf, data, saved_pane) end
    end
  end

  function panel.new(kind, options)
    panel.restore_running()
    if not providers[kind] then return false end
    return panel.provider(kind).new(options, options and options[fields.id] ~= nil)
  end

  function panel.focus(kind, buf, options)
    panel.restore_running()
    if not providers[kind] then return false end
    return panel.provider(kind).focus(buf or container:recent_pane(container:context(), kind), options, true)
  end

  function panel.open(kind, buf, options)
    panel.restore_running()
    if not providers[kind] then return false end
    buf = buf or container:recent_pane(container:context(), kind)
    local api = panel.provider(kind)
    if buf then return api.focus(buf, options) end
    return api.new(options, options and options[fields.id] ~= nil)
  end

  function panel.resume(saved, options)
    panel.restore_running()
    local kind = saved[fields.kind]
    for _, pane in ipairs(container:panes(saved.path, kind)) do
      if vim.b[pane.bufnr][fields.buffer_id] == saved[fields.id] then
        return opts.owner.open(kind, pane.bufnr, options)
      end
    end
    return opts.owner.new(kind, vim.tbl_extend("force", options or {}, opts.resume_options(saved)))
  end

  function panel.reopen(startup)
    panel.restore_running()
    if startup and panel.visible() then return end
    local cwd = container:context()
    local options = startup and { view_mode = true } or nil
    local active = panel.recent_tab(cwd)
    if active then return opts.owner.open(active.kind, active.bufnr, options) end
    local saved = opts.latest(cwd)
    if saved then return opts.owner.resume(saved, options) end
    if not startup then return opts.owner.open(opts.default_kind()) end
  end

  return panel
end

return M
