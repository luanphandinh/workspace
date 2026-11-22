local M = {}

function M.save_view(win, buf)
  if not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then return end
  local ok, view = pcall(vim.api.nvim_win_call, win, vim.fn.winsaveview)
  if ok then
    vim.b[buf].luanphan_terminal_view = { follow = view.lnum >= vim.api.nvim_buf_line_count(buf), view = view }
  end
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
  local job = vim.b[buf].terminal_job_id
  if type(job) ~= "number" or job <= 0 then return end
  local width = vim.api.nvim_win_get_width(win)
  local height = vim.api.nvim_win_get_height(win)
  if vim.wo[win].winbar ~= "" then height = height - 1 end
  width, height = math.max(1, width), math.max(1, height)
  local previous = vim.b[buf].luanphan_terminal_grid
  if type(previous) == "table" and previous.width == width and previous.height == height then return end
  if pcall(vim.fn.jobresize, job, width, height) then
    vim.b[buf].luanphan_terminal_grid = { width = width, height = height }
  end
end

return M
