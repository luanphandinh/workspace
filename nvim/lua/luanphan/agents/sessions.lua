local M = {}
local uv = vim.uv
local backend = require("luanphan.agents.tmux")
local pane_state = require("luanphan.view_container.pane_state")
local uuid = "^" .. string.rep("%x", 8) .. ("%-" .. string.rep("%x", 4)):rep(3) .. "%-" .. string.rep("%x", 12) .. "$"
local providers, names = {}, {}

function M.key(session)
  return session.bufnr or session.agent .. ":" .. session.thread_id
end

function M.setup(definitions, order)
  providers, names = definitions, order
end

function M.supported(agent)
  return providers[agent] and providers[agent].resume ~= nil
end

function M.valid_id(id)
  return type(id) == "string" and id:match(uuid) ~= nil
end

local function state_dir(agent)
  return vim.g["luanphan_" .. agent .. "_sessions_dir"]
    or (vim.fn.stdpath("state") .. "/workspace-" .. agent .. "-sessions")
end

local function session_path(agent, id)
  return state_dir(agent) .. "/" .. id .. ".json"
end

local function read(path, id)
  local record = pane_state.read(path)
  if not record or record.thread_id ~= id
    or type(record.path) ~= "string" or record.path:sub(1, 1) ~= "/"
    or type(record.agent_label) ~= "string" or type(record.last_used) ~= "number" then
    return nil
  end
  return record
end

local function list(agent)
  local dir = state_dir(agent)
  local records = {}
  if vim.fn.isdirectory(dir) ~= 1 then return records end
  for name, kind in vim.fs.dir(dir) do
    local id = name:match("^(.*)%.json$")
    if kind == "file" and id and id:match(uuid) then
      local path = dir .. "/" .. name
      local record = read(path, id)
      if record then
        record.agent = agent
        records[#records + 1] = record
      end
    end
  end
  return records
end

function M.list(agent)
  if agent then return M.supported(agent) and list(agent) or {} end
  local result = {}
  for _, agent in ipairs(names) do
    if M.supported(agent) then vim.list_extend(result, list(agent)) end
  end
  return result
end

function M.live(cwd, closing_bufnr)
  local paths_by_agent = {}
  local function add(agent, path, buf)
    paths_by_agent[agent] = paths_by_agent[agent] or {}
    local paths = paths_by_agent[agent]
    paths[path] = paths[path] or {}
    table.insert(paths[path], buf)
    return paths[path]
  end
  for _, pane in ipairs(backend.panes(nil, cwd)) do
    add(pane.data.agent, pane.data.cwd, pane.bufnr)
  end
  -- A process may exit before the container selects its neighbor.
  if closing_bufnr and not backend.running(closing_bufnr) then
    table.sort(add(vim.b[closing_bufnr].luanphan_agent_name, cwd, closing_bufnr))
  end
  local records = {}
  for _, agent in ipairs(names) do
    for path, bufnrs in pairs(paths_by_agent[agent] or {}) do
      if cwd or vim.fn.isdirectory(path) == 1 then
        for index, bufnr in ipairs(bufnrs) do
          records[#records + 1] = {
            id = bufnr,
            agent = agent,
            label = #bufnrs > 1 and (agent .. " " .. index) or agent,
            bufnr = bufnr,
            path = path,
            last_used = tonumber(vim.b[bufnr].luanphan_agent_last_used) or 0,
          }
        end
      end
    end
  end
  return records
end

function M.instances(include_saved)
  local instances, live = M.live(), {}
  local tab_label = require("luanphan.view_container").tab_label
  for _, record in ipairs(instances) do
    record.agent_label = tab_label(record.bufnr, record.label)
    local id = vim.b[record.bufnr].luanphan_agent_thread_id
    if id then live[record.agent .. ":" .. id] = true end
  end
  if include_saved then
    for _, record in ipairs(M.list()) do
      if not live[record.agent .. ":" .. record.thread_id] and vim.fn.isdirectory(record.path) == 1 then
        instances[#instances + 1] = record
      end
    end
  end
  return instances
end

function M.latest(path)
  local real = uv.fs_realpath(path) or path
  local latest
  for _, record in ipairs(M.list()) do
    if record.path == real and (not latest or record.last_used > latest.last_used) then latest = record end
  end
  return latest
end

function M.forget(agent, id)
  if M.supported(agent) and M.valid_id(id) then
    pane_state.forget(session_path(agent, id))
  end
end

function M.forget_buffer(bufnr, agent, id)
  id = id or vim.b[bufnr].luanphan_agent_thread_id
  if not id then return end
  for _, other in ipairs(vim.api.nvim_list_bufs()) do
    local buf = vim.b[other]
    if other ~= bufnr and buf.luanphan_agent_name == agent and buf.luanphan_agent_thread_id == id then return end
  end
  M.forget(agent, id)
end

function M.snapshot(item)
  local buf = item.bufnr and vim.b[item.bufnr]
  local agent, id, cwd = item.agent, item.thread_id, item.path
  local label, last_used = item.agent_label, item.last_used
  if buf then
    agent, id, cwd = buf.luanphan_agent_name, buf.luanphan_agent_thread_id, buf.luanphan_agent_cwd
  end
  if not M.supported(agent) or not M.valid_id(id) or not cwd then return end
  if buf then
    local saved_title = providers[agent].saved_title
    local title = saved_title and saved_title(item.bufnr)
    if title == false then return end
    label = title and title ~= "" and title or buf.luanphan_agent_saved_label or agent
    last_used = buf.luanphan_agent_saved_use or os.time()
    cwd = uv.fs_realpath(cwd) or cwd
  end
  return session_path(agent, id), {
    thread_id = id,
    path = cwd,
    agent_label = label,
    last_used = last_used,
  }
end

function M.update(bufnr, event)
  local buf = vim.b[bufnr]
  local agent, previous = buf.luanphan_agent_name, buf.luanphan_agent_thread_id
  local id = event.thread_id
  local has_id = M.supported(agent) and M.valid_id(id)
  local changed_id = has_id and previous ~= id
  if changed_id then
    if previous then
      M.forget_buffer(bufnr, agent, previous)
      buf.luanphan_agent_saved_label = nil
    end
    buf.luanphan_agent_thread_id = id
  end
  if has_id or event.save_title then pane_state.save({ bufnr = bufnr }, M.snapshot) end
  return changed_id
end

return M
