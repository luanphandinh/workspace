local M = {}
local tmux = require("luanphan.view_container.tmux.pane")

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

function M.save_view(win, buf)
  if not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then return end
  local pane = tmux.for_buffer(buf)
  if pane then return tmux.save_view(pane, win) end
  local ok, view = pcall(vim.api.nvim_win_call, win, vim.fn.winsaveview)
  if ok then
    vim.b[buf].luanphan_terminal_view = { follow = view.lnum >= vim.api.nvim_buf_line_count(buf), view = view }
  end
end

function M.is_scrolled(buf)
  local pane = tmux.for_buffer(buf)
  if pane then return pane.follow_live == false end
  local saved = vim.b[buf].luanphan_terminal_view
  return type(saved) == "table" and saved.follow == false
end

function M.restore_view(win, buf)
  if not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then return end
  local saved = vim.b[buf].luanphan_terminal_view
  if type(saved) == "table" and saved.follow == false and type(saved.view) == "table" then
    pcall(vim.api.nvim_win_call, win, function() vim.fn.winrestview(saved.view) end)
  end
end

function M.sync_grid(win, buf)
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then return end
  local pane = tmux.for_buffer(buf)
  if pane then
    tmux.sync_grid(pane, win)
    tmux.show_view(pane, win)
    return
  end
  local width, height = tmux.grid_size(win)
  local job = vim.b[buf].terminal_job_id
  if type(job) ~= "number" or job <= 0 then return end
  local previous = vim.b[buf].luanphan_terminal_grid
  if type(previous) == "table" and previous.width == width and previous.height == height then return end
  if pcall(vim.fn.jobresize, job, width, height) then
    vim.b[buf].luanphan_terminal_grid = { width = width, height = height }
  end
end

return M
