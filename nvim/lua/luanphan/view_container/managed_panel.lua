-- Live panes survive UI restarts. Saved records can also reopen a pane after its server exits.
--
-- Providers describe one kind of pane: command, resume args, title parsing, and an optional
-- `decode_event(bufnr, event, emit)` for terminal requests. The panel owns everything else:
-- sessions, status, titles, the window bar data, keymaps, and the remembered default kind.
local window = require("luanphan.view_container.window")
local views = require("luanphan.view_container")
local terminal_session = require("luanphan.view_container.terminal_session")
local terminal = require("luanphan.view_container.terminal")
local pane_status = require("luanphan.view_container.pane_status")
local M = {}

local function icon_highlight(kind)
  return "LuanphanViewIcon" .. kind:gsub("^%l", string.upper)
end

function M.create(owner, opts)
  local backend, providers = opts.backend, opts.providers
  -- A provider's `icon_color` keeps its icon in that color in the sidebar and the tab bar, on any
  -- row or tab highlight. A colorscheme change clears the groups, so they are defined again.
  local function define_icon_highlights()
    for kind, provider in pairs(providers) do
      if provider.icon_color then vim.api.nvim_set_hl(0, icon_highlight(kind), { fg = provider.icon_color }) end
    end
  end
  define_icon_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { callback = define_icon_highlights })
  local sessions = opts.sessions or require("luanphan.view_container.session_store").create({
    valid_id = require("luanphan.view_container.uuid").is_valid, directory = opts.session_dir,
  })
  local panel, apis, restored = { sessions = sessions }, {}, {}
  -- Owners may override the default kind lookup; it is read on every use.
  opts.default_kind = opts.default_kind or function() return panel.default_kind() end

  function panel.display_title(kind, title)
    local provider = providers[kind]
    if provider and provider.display_title then return provider.display_title(title) end
    return title
  end

  local function pane_title(buf, title)
    local vars = vim.b[buf]
    title = panel.display_title(vars.luanphan_view_kind, title)
    if type(title) ~= "string" or title == "" or title == vim.api.nvim_buf_get_name(buf) then
      return vars.luanphan_view_saved_label
    end
    return title
  end

  -- Kinds a user can pick as the default: every provider except plain shells.
  local function default_choices()
    local choices = {}
    for _, kind in ipairs(opts.kinds) do
      if not providers[kind].shell then
        choices[#choices + 1] = { id = kind, label = kind, display = kind, ordinal = kind }
      end
    end
    return choices
  end

  local function choosable(kind)
    return providers[kind] ~= nil and not providers[kind].shell
  end

  function panel.default_kind()
    local ok, lines = pcall(vim.fn.readfile, opts.default_kind_file(), "", 1)
    local kind = ok and vim.trim(lines[1] or "") or ""
    return choosable(kind) and kind or default_choices()[1].id
  end

  function panel.set_default_kind(kind)
    if not choosable(kind) then return false end
    local path = opts.default_kind_file()
    local ok = pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ":h"), "p")
    local wrote, result = pcall(vim.fn.writefile, { kind }, path)
    if not ok or not wrote or result ~= 0 then
      vim.notify("Could not save the default " .. opts.noun, vim.log.levels.ERROR)
      return false
    end
    vim.notify("Default " .. opts.noun .. ": " .. kind)
    return true
  end

  function panel.pick_default_kind()
    local current = panel.default_kind()
    local choices = default_choices()
    for _, choice in ipairs(choices) do
      if choice.id == current then choice.display = choice.label .. " (current)" end
    end
    views.select(opts.default_title or ("Default " .. opts.noun), choices, function(choice) panel.set_default_kind(choice.id) end,
      opts.view.picker_opts)
  end

  local function new_keys()
    local keys = {
      { "<leader>na", function() owner.new(opts.default_kind()) end, "New default " .. opts.noun },
      { "<leader>nA", function() owner.container:pick() end, "Select " .. opts.noun },
    }
    local shell = vim.iter(opts.kinds):find(function(kind) return providers[kind].shell end)
    if shell then table.insert(keys, 1, { "<leader>nt", function() owner.new(shell) end, "New terminal" }) end
    return keys
  end

  local function bind_actions(bufnr, sidebar)
    if sidebar and opts.toggle then vim.keymap.set("n", opts.hint_open, opts.toggle, { buffer = bufnr }) end
    -- Keep the editor's New buffer mapping from replacing a panel buffer.
    vim.keymap.set("n", "<leader>fn", "<Nop>", { buffer = bufnr, silent = true, nowait = true })
  end

  local container = views.create(vim.tbl_extend("force", {
    title = function(buf, title) return pane_title(buf, title) end,
    choices = default_choices,
    new_keys = new_keys,
    bind_actions = bind_actions,
    context = vim.fn.getcwd,
    panes = {
      backend = backend, kinds = opts.kinds,
      kind = function(buf) return vim.b[buf].luanphan_view_kind end,
      last_used = function(buf) return tonumber(vim.b[buf].luanphan_view_last_used) or 0 end,
    },
    snapshot = sessions.snapshot,
    activate = function(tab, options) return owner.open(tab.kind, tab.bufnr, options) end,
    create = function(choice) return owner.new(choice.id) end,
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

  -- Applies what a terminal request said about its pane. Runs outside the TermRequest callback.
  local function apply_event(bufnr, kind, event)
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.b[bufnr].luanphan_view_kind ~= kind then return end
    local status_changed = event.status and pane_status.update(bufnr, event.status)
    local changed_id = sessions.update(bufnr, event)
    panel.remember(bufnr)
    local bar = container.opts.bar()
    if changed_id then
      bar:refresh(true)
    else
      if event.refresh_title then bar:update_title(bufnr, views.tab_label(bufnr)) end
      if status_changed then bar:status_changed() end
    end
  end

  local function term_request(args)
    local bufnr, sequence = args.buf, args.data and args.data.sequence
    local kind = vim.b[bufnr].luanphan_view_kind
    local provider = providers[kind]
    if not provider or not sequence then return end
    local decode = provider.status and provider.status.decode or pane_status.from_osc
    local status = decode(sequence)
    local title = terminal.request_title(sequence)
    -- Decoders may call emit from inside the terminal callback; the work always runs later.
    local function emit(event) vim.schedule(function() apply_event(bufnr, kind, event) end) end
    if status then emit({ status = status }) end
    if provider.decode_event then
      provider.decode_event(bufnr, { sequence = sequence, title = title, status = status }, emit)
    elseif title then
      emit({ refresh_title = true })
    end
  end

  local function watch(group)
    vim.api.nvim_create_autocmd({ "VimEnter", "UIEnter" }, {
      group = group, callback = function() vim.schedule(function() restore_ui(opts.startup_flag) end) end,
    })
    vim.api.nvim_create_autocmd("TermRequest", { group = group, callback = term_request })
    window.track_directory(group, function(cwd)
      local pane = panel.visible()
      if pane and container:current_context() == cwd then return pane end
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
      local provider = providers[kind]
      local initial = provider.status and provider.status.initial
      local api = terminal_session.create(vim.tbl_extend("force", provider, {
        name = kind, panel = owner, backend = backend, container = container, hint_open = opts.hint_open,
        defaults = vim.tbl_deep_extend("force", { args = {} }, opts.defaults or {}, provider.defaults or {}),
        augroup = opts.group .. "_" .. kind,
        notify = function(message, level) vim.notify(kind .. ": " .. message, level or vim.log.levels.INFO) end,
        on_register = function(buf)
          if initial and not pane_status.current(buf) then pane_status.update(buf, initial) end
        end,
        current = function() return container:recent_pane(container:context(), kind, true) end,
        cwd = function(buf) return vim.b[buf].luanphan_view_cwd end,
        on_show = panel.show, mark_used = panel.mark_used, on_close = panel.close,
        metadata = function(buf, cwd, options) return metadata(kind, buf, cwd, options) end,
        on_adopt = adopt,
      }))
      if opts.extend_api then opts.extend_api(api, kind) end
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
        vim.b[buf].luanphan_view_saved_label = saved_pane and saved_pane.label or panel.display_title(kind, data.label)
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

  function panel.plugin_specs(keys)
    local specs = {}
    local function init() watch(vim.api.nvim_create_augroup(opts.startup_group, { clear = true })) end
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
    if except and container:visible_window(container:current_context(), except) then return false end
    return container:hide()
  end

  -- Live and saved panes, each tagged with the workspace it is grouped under.
  function panel.instances(include_saved)
    owner.restore_running()
    local instances, workspaces = sessions.instances(include_saved), {}
    for _, instance in ipairs(instances) do
      local cwd = instance.path
      if workspaces[cwd] == nil then workspaces[cwd] = opts.workspace(cwd) end
      instance.workspace = workspaces[cwd]
    end
    return instances
  end

  -- A window bar listing every pane by workspace, with status glyphs and saved-session dismissal.
  function panel.create_bar(bar_opts)
    local bar
    bar = container:create_bar(vim.tbl_extend("force", {
      groups = function()
        return views.workspace_groups(panel.instances(true), function(instance)
          return {
            id = sessions.key(instance), sort_id = instance.thread_id, bufnr = instance.bufnr,
            label = instance.label, icon = providers[instance.kind].icon, thread = instance,
            icon_hl = providers[instance.kind].icon_color and icon_highlight(instance.kind) or nil,
            pane_order = instance.pane_order,
          }
        end)
      end,
      reorder = function(_, items)
        container:reorder_panes(vim.tbl_map(function(item) return item.thread end, items))
      end,
      status = function(item, frame) return pane_status.glyph(item.bufnr, frame) end,
      dismiss = function(item)
        local session = item and item.thread
        if session and session.thread_id and not session.bufnr then
          sessions.forget(session.kind, session.thread_id)
          bar:refresh(true)
        end
      end,
    }, bar_opts))
    return bar
  end

  owner.container = container
  sessions.setup(providers, opts.kinds, container)
  container:watch(vim.api.nvim_create_augroup(opts.group, { clear = true }))
  return panel
end

return M
