local M = {}
local pty = require("luanphan.view_container.tmux.pane")

local function managed_process(buf)
  local pane = pty.for_buffer(buf)
  return pane and pane.process
end

function M.running(buf)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "terminal" then return false end
  local backend = managed_process(buf)
  if backend then return backend.running(buf) end
  local job = vim.b[buf].terminal_job_id
  if type(job) ~= "number" or job <= 0 then return false end
  local ok, status = pcall(vim.fn.jobwait, { job }, 0)
  return ok and status[1] == -1
end

function M.send(buf, bytes)
  local backend = managed_process(buf)
  if backend then return backend.send(buf, bytes) end
  local job = vim.b[buf].terminal_job_id
  if type(job) ~= "number" or job <= 0 then return false end
  local ok, result = pcall(vim.fn.chansend, job, bytes)
  return ok and result > 0
end

function M.stop(buf)
  local backend = managed_process(buf)
  if backend then return backend.stop(buf) end
  local job = vim.b[buf].terminal_job_id
  if type(job) ~= "number" or job <= 0 then return false end
  return vim.fn.jobstop(job) == 1
end

return M
