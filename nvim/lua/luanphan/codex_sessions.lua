local M = {}
local uv = vim.uv
local pending = {}
local uuid_prefix = string.rep("%x", 8) .. ("%-" .. string.rep("%x", 4)):rep(3) .. "%-" .. string.rep("%x", 5)
local uuid = "^" .. uuid_prefix .. string.rep("%x", 7) .. "$"

local function state_dir()
  return vim.g.luanphan_codex_sessions_dir or (vim.fn.stdpath("state") .. "/workspace-codex-sessions")
end

function M.launch_args(id)
  local args = { "resume", "-c", 'tui.terminal_title=["session-id","thread-name"]' }
  if id then table.insert(args, 2, id) end
  return args
end

local function parse_title(title)
  if type(title) ~= "string" then return nil end
  local prefix, label = title:match("^(" .. uuid_prefix .. ")%.%.%.(.*)$")
  if not prefix then return nil end
  label = vim.trim(label):gsub("^|%s*", "")
  return prefix:lower(), label
end

function M.display_title(title)
  local _, label = parse_title(title)
  return label or title
end

local function read(id)
  local ok, lines = pcall(vim.fn.readfile, state_dir() .. "/" .. id .. ".json")
  if not ok then return nil end
  local decoded, record = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded or type(record) ~= "table" or record.thread_id ~= id
    or type(record.path) ~= "string" or record.path:sub(1, 1) ~= "/"
    or type(record.agent_label) ~= "string" or type(record.last_used) ~= "number" then
    return nil
  end
  return record
end

function M.list()
  local dir = state_dir()
  local records = {}
  if vim.fn.isdirectory(dir) ~= 1 then return records end
  for name, kind in vim.fs.dir(dir) do
    local id = name:match("^(.*)%.json$")
    if kind == "file" and id and id:match(uuid) then
      local record = read(id)
      if record then records[#records + 1] = record end
    end
  end
  return records
end

function M.latest(path)
  local real = uv.fs_realpath(path) or path
  local latest
  for _, record in ipairs(M.list()) do
    if record.path == real and (not latest or record.last_used > latest.last_used) then latest = record end
  end
  return latest
end

function M.forget(id)
  if type(id) == "string" and id:match(uuid) then
    uv.fs_unlink(state_dir() .. "/" .. id .. ".json")
  end
end

function M.forget_buffer(bufnr, id)
  id = id or vim.b[bufnr].luanphan_agent_thread_id
  if not id then return end
  for _, other in ipairs(vim.api.nvim_list_bufs()) do
    if other ~= bufnr and vim.b[other].luanphan_agent_thread_id == id then return end
  end
  M.forget(id)
end

function M.save(bufnr)
  local buf = vim.b[bufnr]
  local id, cwd = buf.luanphan_agent_thread_id, buf.luanphan_agent_cwd
  if not id or not id:match(uuid) or not cwd then return end
  local prefix, label = parse_title(buf.term_title)
  if prefix and not vim.startswith(id, prefix) then return end
  local record = {
    thread_id = id,
    path = uv.fs_realpath(cwd) or cwd,
    agent_label = label and label ~= "" and label or buf.luanphan_agent_saved_label or "codex",
    last_used = buf.luanphan_agent_saved_use or os.time(),
  }
  if vim.deep_equal(read(id), record) then return end
  local dir = state_dir()
  if not pcall(vim.fn.mkdir, dir, "p", 448) then return end
  local path = dir .. "/" .. id .. ".json"
  local tmp = path .. "." .. vim.fn.getpid() .. ".tmp"
  local wrote, result = pcall(vim.fn.writefile, { vim.json.encode(record) }, tmp, "s")
  if wrote and result == 0 then
    uv.fs_rename(tmp, path)
  end
  uv.fs_unlink(tmp)
end

local function candidates(output, prefix)
  local found
  for line in output:gmatch("[^\r\n]+") do
    local id = line:match(uuid) and line or line:match("(" .. uuid:sub(2, -2) .. ")%.jsonl$")
    if id and vim.startswith(id, prefix) then
      if found and found ~= id then return nil end
      found = id
    end
  end
  return found
end

local function resolve(prefix, callback)
  local home = vim.env.CODEX_HOME or (vim.fn.expand("~") .. "/.codex")
  local function rollouts()
    if vim.fn.executable("rg") ~= 1 then return callback(nil) end
    vim.system({ "rg", "--files", "-g", "*" .. prefix .. "*.jsonl", home .. "/sessions" },
      { text = true, timeout = 2000 }, vim.schedule_wrap(function(result)
        callback(candidates(result.stdout or "", prefix))
      end))
  end
  if vim.fn.executable("sqlite3") ~= 1 then return rollouts() end
  local db_home = vim.env.CODEX_SQLITE_HOME or home
  local database
  local version = 0
  if vim.fn.isdirectory(db_home) == 1 then
    for name in vim.fs.dir(db_home) do
      local current = tonumber(name:match("^state_(%d+)%.sqlite$")) or 0
      if current > version then version, database = current, db_home .. "/" .. name end
    end
  end
  if not database then return rollouts() end
  local sql = "SELECT id FROM threads WHERE archived = 0 AND id GLOB '" .. prefix .. "*' LIMIT 2"
  vim.system({ "sqlite3", "-readonly", database, sql }, { text = true, timeout = 2000 },
    vim.schedule_wrap(function(result)
      local output = vim.trim(result.stdout or "")
      if result.code == 0 and output ~= "" then return callback(candidates(output, prefix)) end
      rollouts()
    end))
end

function M.observe(bufnr, attempt)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local buf = vim.b[bufnr]
  if buf.luanphan_agent_name ~= "codex" then return end
  local prefix = parse_title(buf.term_title)
  if not prefix then return end
  if vim.startswith(buf.luanphan_agent_thread_id or "", prefix) then
    M.save(bufnr)
    return
  end
  if pending[bufnr] == prefix then return end
  pending[bufnr] = prefix
  resolve(prefix, function(id)
    if pending[bufnr] ~= prefix then return end
    pending[bufnr] = nil
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if parse_title(buf.term_title) ~= prefix then return end
    if not id then
      if (attempt or 0) < 3 then
        vim.defer_fn(function() M.observe(bufnr, (attempt or 0) + 1) end, 500)
      end
      return
    end
    M.forget_buffer(bufnr)
    buf.luanphan_agent_thread_id = id
    M.save(bufnr)
    local sidebar = package.loaded["luanphan.agent_sidebar"]
    if sidebar then sidebar.refresh(true) end
  end)
end

return M
