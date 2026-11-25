local M = {}

local function agent_backend(buf)
  if vim.b[buf].luanphan_agent_tmux_pane then
    return require("luanphan.agents.tmux")
  end
end

function M.running(buf)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "terminal" then return false end
  local backend = agent_backend(buf)
  if backend then return backend.running(buf) end
  local job = vim.b[buf].terminal_job_id
  if type(job) ~= "number" or job <= 0 then return false end
  local ok, status = pcall(vim.fn.jobwait, { job }, 0)
  return ok and status[1] == -1
end

function M.send(buf, bytes)
  local backend = agent_backend(buf)
  if backend then return backend.send(buf, bytes) end
  local job = vim.b[buf].terminal_job_id
  if type(job) ~= "number" or job <= 0 then return false end
  local ok, result = pcall(vim.fn.chansend, job, bytes)
  return ok and result > 0
end

function M.stop(buf)
  local backend = agent_backend(buf)
  if backend then return backend.stop(buf) end
  local job = vim.b[buf].terminal_job_id
  if type(job) ~= "number" or job <= 0 then return false end
  return vim.fn.jobstop(job) == 1
end

return M
