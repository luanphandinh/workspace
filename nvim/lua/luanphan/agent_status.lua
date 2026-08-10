local M = {}

local valid_status = {
  idle = true,
  running = true,
}

local function state_dir()
  return vim.g.luanphan_agent_status_dir
    or (vim.fn.stdpath("state") .. "/workspace-agent-status")
end

local function normalized_cwd(cwd)
  return vim.uv.fs_realpath(cwd) or cwd:gsub("/$", "")
end

function M.path(agent, cwd)
  local key = agent:lower() .. "\n" .. normalized_cwd(cwd)
  return state_dir() .. "/" .. vim.fn.sha256(key)
end

function M.read(agent, cwd)
  local path = M.path(agent, cwd)
  if vim.fn.filereadable(path) ~= 1 then
    return "unknown"
  end
  local lines = vim.fn.readfile(path, "", 1)
  local status = lines[1]
  if not valid_status[status] then
    return "unknown"
  end
  return status
end

function M.write(agent, cwd, status)
  if not valid_status[status] then
    return false
  end
  local path = M.path(agent, cwd)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local tmp = path .. "." .. vim.fn.getpid()
  if vim.fn.writefile({ status }, tmp) ~= 0 then
    return false
  end
  local ok = vim.uv.fs_rename(tmp, path)
  if not ok then
    pcall(vim.fn.delete, tmp)
    return false
  end
  return true
end

return M
