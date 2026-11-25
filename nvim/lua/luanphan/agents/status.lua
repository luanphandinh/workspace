local M = {}

local live_status = {
  idle = true, working = true, done = true, blocked = true, error = true, clear = true,
}

function M.update(bufnr, status)
  if live_status[status] then vim.b[bufnr].luanphan_agent_program_status = status end
end

function M.from_osc(sequence)
  return sequence:match("^\27%]7501;state=(%a+)")
end

function M.current(bufnr)
  return vim.b[bufnr].luanphan_agent_program_status
end

return M
