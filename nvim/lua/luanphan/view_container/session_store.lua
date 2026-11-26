local pane_state = require("luanphan.view_container.pane_state")
local tab_label = require("luanphan.view_container").tab_label
local uv = vim.uv
local M = {}

---@class ViewSession
---@field kind string
---@field thread_id? string
---@field label string
---@field path string
---@field last_used number
---@field bufnr? integer
function M.create(opts)
  local store = { valid_id = opts.valid_id }
  local providers, names, container = {}, {}

  ---@param record ViewSession
  function store.key(record)
    return record.bufnr or record.kind .. ":" .. record.thread_id
  end

  function store.setup(definitions, order, view)
    providers, names, container = definitions, order, view
  end

  function store.supported(kind)
    return providers[kind] and providers[kind].resume ~= nil
  end

  local function session_path(kind, id)
    return opts.directory(kind) .. "/" .. id .. ".json"
  end

  local function list(kind)
    local records = {}
    for id, record in pairs(pane_state.list(opts.directory(kind), store.valid_id)) do
      record.label, record.agent_label = record.agent_label, nil
      if record.thread_id == id and type(record.path) == "string" and record.path:sub(1, 1) == "/"
        and type(record.label) == "string" and type(record.last_used) == "number" then
        record.kind = kind
        records[#records + 1] = record
      end
    end
    return records
  end

  function store.list(kind)
    if kind then return store.supported(kind) and list(kind) or {} end
    local result = {}
    for _, kind in ipairs(names) do
      if store.supported(kind) then vim.list_extend(result, list(kind)) end
    end
    return result
  end

  function store.instances(include_saved)
    local instances, live = container and container:live_tabs() or {}, {}
    for _, record in ipairs(instances) do
      record.label = tab_label(record.bufnr, record.label)
      local id = vim.b[record.bufnr].luanphan_view_thread_id
      if id then live[record.kind .. ":" .. id] = true end
    end
    if include_saved then
      local directories = {}
      for _, record in ipairs(store.list()) do
        if directories[record.path] == nil then directories[record.path] = vim.fn.isdirectory(record.path) == 1 end
        if not live[store.key(record)] and directories[record.path] then
          instances[#instances + 1] = record
        end
      end
    end
    return instances
  end

  function store.latest(path)
    local real = uv.fs_realpath(path) or path
    local latest
    for _, record in ipairs(store.list()) do
      if record.path == real and (not latest or record.last_used > latest.last_used) then latest = record end
    end
    return latest
  end

  function store.forget(kind, id)
    if store.supported(kind) and store.valid_id(id) then
      pane_state.forget(session_path(kind, id))
    end
  end

  function store.forget_buffer(bufnr, kind, id)
    id = id or vim.b[bufnr].luanphan_view_thread_id
    if not id then return end
    for _, pane in ipairs(container:panes(nil, kind)) do
      if pane.bufnr ~= bufnr and vim.b[pane.bufnr].luanphan_view_thread_id == id then return end
    end
    store.forget(kind, id)
  end

  function store.snapshot(item)
    local buf = item.bufnr and vim.b[item.bufnr]
    local kind, id, cwd = item.kind, item.thread_id, item.path
    local label, last_used = item.label, item.last_used
    if buf then
      kind, id, cwd = buf.luanphan_view_kind, buf.luanphan_view_thread_id, buf.luanphan_view_cwd
    end
    if not store.supported(kind) or not store.valid_id(id) or not cwd then return end
    if buf then
      local saved_title = providers[kind].saved_title
      local title = saved_title and saved_title(item.bufnr)
      if title == false then return end
      label = title and title ~= "" and title or buf.luanphan_view_saved_label or kind
      last_used = buf.luanphan_view_used_at or os.time()
      cwd = uv.fs_realpath(cwd) or cwd
    end
    return session_path(kind, id), {
      thread_id = id,
      path = cwd,
      agent_label = label, -- existing on-disk format
      last_used = last_used,
    }
  end

  function store.update(bufnr, event)
    local buf = vim.b[bufnr]
    local agent, previous = buf.luanphan_view_kind, buf.luanphan_view_thread_id
    local id = event.thread_id
    local has_id = store.supported(agent) and store.valid_id(id)
    local changed_id = has_id and previous ~= id
    if changed_id then
      if previous then
        store.forget_buffer(bufnr, agent, previous)
        buf.luanphan_view_saved_label = nil
      end
      buf.luanphan_view_thread_id = id
    end
    if has_id or event.save_title then pane_state.save({ bufnr = bufnr }, store.snapshot) end
    return changed_id
  end

  return store
end

return M
