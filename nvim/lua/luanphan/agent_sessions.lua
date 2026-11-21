local M = {}
local uv = vim.uv
local uuid = "^" .. string.rep("%x", 8) .. ("%-" .. string.rep("%x", 4)):rep(3) .. "%-" .. string.rep("%x", 12) .. "$"

function M.supported(agent)
  return agent == "codex" or agent == "cursor"
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

function M.list()
  return vim.list_extend(list("codex"), list("cursor"))
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

function M.save(bufnr, label)
  local buf = vim.b[bufnr]
  local agent, id, cwd = buf.luanphan_agent_name, buf.luanphan_agent_thread_id, buf.luanphan_agent_cwd
  if not M.supported(agent) or not M.valid_id(id) or not cwd then return end
  if agent == "cursor" then label = require("luanphan.view_container").tab_label(bufnr, agent) end
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

function M.capture(bufnr, id, label)
  local buf = vim.b[bufnr]
  local agent, previous = buf.luanphan_agent_name, buf.luanphan_agent_thread_id
  if not M.supported(agent) or not M.valid_id(id) then return false end
  if previous ~= id then
    if previous then
      M.forget_buffer(bufnr, agent, previous)
      buf.luanphan_agent_saved_label = nil
    end
    buf.luanphan_agent_thread_id = id
  end
  M.save(bufnr, label)
  if previous ~= id then
    local sidebar = package.loaded["luanphan.agent_sidebar"]
    if sidebar then sidebar.refresh(true) end
  end
  return true
end

-- Cursor's status indicators prefix the title suffix with these symbols.
local cursor_status = {
  ["📤"] = "working", ["📂"] = "loading", ["🔄"] = "working",
  ["⌨️"] = "working", ["🧭"] = "working", ["⏳"] = "working",
  ["📋"] = "working", ["📝"] = "working",
  ["❓"] = "blocked", ["🔐"] = "blocked", ["✅"] = "idle",
}

function M.cursor_title(title)
  if type(title) ~= "string" then return title end
  local name, icon = title:match("^(.*) %- (%S+) ")
  local status = cursor_status[icon]
  if not status then return title end
  return name, status
end

return M
