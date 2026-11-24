local M = {}
local uv = vim.uv
local terminal = require("luanphan.agents.terminal-chat")
local uuid = "^" .. string.rep("%x", 8) .. ("%-" .. string.rep("%x", 4)):rep(3) .. "%-" .. string.rep("%x", 12) .. "$"
local providers, names = {}, {}
local order = {}

function M.key(session)
  return session.order_key or session.bufnr or session.agent .. ":" .. session.thread_id
end

function M.set_order(sessions)
  for index, session in ipairs(sessions) do order[M.key(session)] = index end
end

function M.sort_by_order(sessions)
  if #sessions < 2 or not next(order) then return end
  local positions, ranks = {}, {}
  for index, session in ipairs(sessions) do
    positions[session] = index
    ranks[session] = order[M.key(session)] or math.huge
  end
  table.sort(sessions, function(a, b)
    if ranks[a] ~= ranks[b] then return ranks[a] < ranks[b] end
    return positions[a] < positions[b]
  end)
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

local function read(agent, id)
  local ok, lines = pcall(vim.fn.readfile, state_dir(agent) .. "/" .. id .. ".json")
  if not ok then return nil end
  local decoded, record = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded or type(record) ~= "table" or record.thread_id ~= id
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
      local record = read(agent, id)
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

function M.instances(include_saved)
  local instances, live = {}, {}
  local tab_label = require("luanphan.view_container").tab_label
  for _, agent in ipairs(names) do
    local buffers = vim.g[providers[agent].g_bufnr]
    for cwd, bufnrs in pairs(type(buffers) == "table" and buffers or {}) do
      if type(cwd) == "string" and vim.fn.isdirectory(cwd) == 1 and type(bufnrs) == "table" then
        for index, bufnr in ipairs(bufnrs) do
          if terminal.running(bufnr) then
            local buf = vim.b[bufnr]
            local id = buf.luanphan_agent_thread_id
            instances[#instances + 1] = {
              agent = agent,
              agent_label = tab_label(bufnr, #bufnrs > 1 and (agent .. " " .. index) or agent),
              bufnr = bufnr,
              path = cwd,
              last_used = tonumber(buf.luanphan_agent_last_used) or 0,
            }
            if id then live[agent .. ":" .. id] = true end
          end
        end
      end
    end
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
    uv.fs_unlink(state_dir(agent) .. "/" .. id .. ".json")
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

function M.save(bufnr)
  local buf = vim.b[bufnr]
  local agent, id, cwd = buf.luanphan_agent_name, buf.luanphan_agent_thread_id, buf.luanphan_agent_cwd
  if not M.supported(agent) or not M.valid_id(id) or not cwd then return end
  local saved_title = providers[agent].saved_title
  local label = saved_title and saved_title(bufnr)
  if label == false then return end
  local record = {
    thread_id = id,
    path = uv.fs_realpath(cwd) or cwd,
    agent_label = label and label ~= "" and label or buf.luanphan_agent_saved_label or agent,
    last_used = buf.luanphan_agent_saved_use or os.time(),
  }
  if vim.deep_equal(read(agent, id), record) then return end
  local dir = state_dir(agent)
  if not pcall(vim.fn.mkdir, dir, "p", 448) then return end
  local path = dir .. "/" .. id .. ".json"
  local tmp = path .. "." .. vim.fn.getpid() .. ".tmp"
  local wrote, result = pcall(vim.fn.writefile, { vim.json.encode(record) }, tmp, "s")
  if wrote and result == 0 then
    uv.fs_rename(tmp, path)
  end
  uv.fs_unlink(tmp)
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
  if has_id or event.save_title then M.save(bufnr) end
  return changed_id
end

return M
