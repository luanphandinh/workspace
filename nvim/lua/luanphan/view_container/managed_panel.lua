-- Live panes survive UI restarts. Saved records can also reopen a pane after its server exits.
local window = require("luanphan.view_container.window")
local views = require("luanphan.view_container")
local M = {}

function M.create(owner, opts)
  local backend, providers, sessions = opts.backend, opts.providers, opts.sessions
  local panel, apis, restored = {}, {}, {}
  local container = views.create(vim.tbl_extend("force", {
    context = vim.fn.getcwd,
    panes = {
      backend = backend, kinds = opts.kinds,
      kind = function(buf) return vim.b[buf].luanphan_view_kind end,
      last_used = function(buf) return tonumber(vim.b[buf].luanphan_view_last_used) or 0 end,
    },
    snapshot = sessions.snapshot,
    activate = function(tab, options) return owner.open(tab.kind, tab.bufnr, options) end,
    create = function(choice) return owner.new(choice.id) end,
    create_key = false,
  }, opts.view))

  function panel.remember(buf)
    local vars = vim.b[buf]
    backend.update(buf, {
      thread_id = vars.luanphan_view_thread_id, status = vars.luanphan_view_status,
      used = vars.luanphan_view_last_used, used_at = vars.luanphan_view_used_at,
      title = vars.term_title, label = views.tab_label(buf, vars.luanphan_view_kind),
    })
  end

  local function adopt(buf, data)
    local vars = vim.b[buf]
    vars.luanphan_view_thread_id = data.thread_id
    vars.luanphan_view_status = data.status
    vars.luanphan_view_last_used = data.used
    vars.luanphan_view_used_at = data.used_at
    vars.luanphan_view_saved_label = data.label
  end

  function panel.visible()
    local win = container:content_window()
    if not win then return end
    local buf = vim.api.nvim_win_get_buf(win)
    local kind = container.opts.panes.kind(buf)
    if providers[kind] then return { kind = kind, bufnr = buf } end
  end

  local function restore_ui(flag)
    if vim.g[flag] or vim.v.vim_did_enter == 0 or #vim.api.nvim_list_uis() == 0 then return end
    vim.g[flag] = true
    panel.reopen(true)
  end

  local function watch(group, term_request)
    vim.api.nvim_create_autocmd({ "VimEnter", "UIEnter" }, {
      group = group, callback = function() vim.schedule(function() restore_ui(opts.startup_flag) end) end,
    })
    vim.api.nvim_create_autocmd("TermRequest", { group = group, callback = term_request })
    window.track_directory(group, function(cwd)
      local pane = panel.visible()
      if pane and container.layout_context == cwd then return pane end
    end, function() container:hide() end, function(cwd, pane)
      if panel.visible() then return end
      local buf = backend.running(pane.bufnr) and pane.bufnr or container:recent_pane(cwd, pane.kind)
      if buf then owner.open(pane.kind, buf) end
    end)
  end

  local function resume_options(saved)
    local provider = providers[saved.kind]
    return {
      args = provider.resume(saved.thread_id), thread_id = saved.thread_id, saved_pane = saved,
      label = not provider.restore_on_open and saved.label or nil,
    }
  end

  local function metadata(kind, buf, cwd, options)
    local id = options and options.thread_id
    local generate = providers[kind].new_session_id
    if not id and generate then id = generate() end
    local label = options and options.label
    local vars = vim.b[buf]
    vars.luanphan_view_thread_id, vars.luanphan_view_saved_label = id, label
    return { cwd = cwd, workspace = opts.workspace(cwd), kind = kind, thread_id = id, label = label or kind }
  end

  function panel.provider(kind)
    if not apis[kind] then
      local api = opts.create(vim.tbl_extend("force", providers[kind], {
        name = kind, panel = owner, backend = backend, container = container, hint_open = opts.hint_open,
        current = function() return container:recent_pane(container:context(), kind, true) end,
        cwd = function(buf) return vim.b[buf].luanphan_view_cwd end,
        on_show = panel.show, mark_used = panel.mark_used, on_close = panel.close,
        metadata = function(buf, cwd, options) return metadata(kind, buf, cwd, options) end,
        on_adopt = adopt,
      }))
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
    local sequence = (tonumber(vim.g.luanphan_view_use_sequence) or 0) + 1
    vim.g.luanphan_view_use_sequence = sequence
    return sequence
  end

  function panel.show(buf, cwd)
    backend.focus(buf)
    local seconds, micros = vim.uv.gettimeofday()
    vim.b[buf].luanphan_view_used_at = seconds + micros / 1000000
    panel.remember(buf)
    if restored[cwd] then return end
    restored[cwd] = true
    local path = vim.uv.fs_realpath(cwd) or cwd
    for _, kind in ipairs(container.opts.panes.kinds) do
      if providers[kind].restore_on_open then
        local live = {}
        for _, pane in ipairs(container:panes(cwd, kind)) do
          local id = vim.b[pane.bufnr].luanphan_view_thread_id
          if id then live[id] = true end
        end
        local saved = sessions.list(kind)
        table.sort(saved, function(a, b)
          if a.last_used ~= b.last_used then return a.last_used < b.last_used end
          return a.thread_id < b.thread_id
        end)
        for _, record in ipairs(saved) do
          if record.path == path and not live[record.thread_id] then
            panel.provider(kind).start_hidden(cwd, resume_options(record))
          end
        end
      end
    end
  end

  function panel.mark_used(buf)
    vim.b[buf].luanphan_view_last_used = next_use()
  end

  function panel.close(buf, cwd)
    if vim.b[buf].luanphan_view_backend_lost then
      restored[cwd] = nil
    elseif type(vim.v.exiting) ~= "number" then
      local kind, id = vim.b[buf].luanphan_view_kind, vim.b[buf].luanphan_view_thread_id
      if sessions.supported(kind) and id then return function() sessions.forget_buffer(buf, kind, id) end end
    end
  end

  function owner.restore_running()
    local running = {}
    backend.restore(function(record)
      if providers[record.data.kind] and vim.fn.isdirectory(record.data.cwd) == 1 then
        running[#running + 1] = record
      end
    end)
    if #running == 0 then return end
    local saved = {}
    for _, record in ipairs(sessions.list()) do saved[sessions.key(record)] = record end
    for _, record in ipairs(running) do
      local data = record.data
      record.saved = data.thread_id and saved[sessions.key(data)]
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
      local buf = panel.provider(data.kind).adopt(record, saved_pane)
      if buf then
        local kind = data.kind
        vim.b[buf].luanphan_view_saved_label = saved_pane and saved_pane.label or opts.display_title(kind, data.label)
      end
    end
  end

  function owner.new(kind, options)
    owner.restore_running()
    if not providers[kind] then return false end
    return panel.provider(kind).new(options, options and options.thread_id ~= nil)
  end

  function owner.focus(kind, buf, options)
    owner.restore_running()
    if not providers[kind] then return false end
    return panel.provider(kind).focus(buf or container:recent_pane(container:context(), kind), options, true)
  end

  function owner.open(kind, buf, options)
    owner.restore_running()
    if not providers[kind] then return false end
    buf = buf or container:recent_pane(container:context(), kind)
    local api = panel.provider(kind)
    if buf then return api.focus(buf, options) end
    return api.new(options, options and options.thread_id ~= nil)
  end

  function owner.resume(saved, options)
    if not sessions.supported(saved.kind) or not sessions.valid_id(saved.thread_id) then return false end
    owner.restore_running()
    local kind = saved.kind
    for _, pane in ipairs(container:panes(saved.path, kind)) do
      if vim.b[pane.bufnr].luanphan_view_thread_id == saved.thread_id then
        return owner.open(kind, pane.bufnr, options)
      end
    end
    return owner.new(kind, vim.tbl_extend("force", options or {}, resume_options(saved)))
  end

  function panel.reopen(startup)
    owner.restore_running()
    if startup and panel.visible() then return end
    local cwd = container:context()
    local options = startup and { view_mode = true } or nil
    local buf = container:recent_pane(cwd)
    if buf then return owner.open(container.opts.panes.kind(buf), buf, options) end
    local saved = sessions.latest(cwd)
    if saved then return owner.resume(saved, options) end
    if not startup then return owner.open(opts.default_kind()) end
  end

  function panel.plugin_specs(keys, term_request)
    local specs = {}
    local function init() watch(vim.api.nvim_create_augroup(opts.startup_group, { clear = true }), term_request) end
    for _, kind in ipairs(opts.kinds) do
      local plugin = providers[kind].plugin
      if plugin then
        local primary = #specs == 0
        specs[#specs + 1] = {
          plugin, virtual = true, keys = primary and keys or {}, init = primary and init or nil,
          config = function() panel.provider(kind) end,
        }
      end
    end
    return specs
  end

  function owner.hide(except)
    if except and container:visible_window(container.layout_context, except) then return false end
    return container:hide()
  end

  owner.container = container
  sessions.setup(providers, opts.kinds, container)
  container:watch(vim.api.nvim_create_augroup(opts.group, { clear = true }))
  return panel
end

return M
