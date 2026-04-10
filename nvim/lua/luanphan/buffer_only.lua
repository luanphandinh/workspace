-- Close other file buffers like VS Code "Close Other Editors" / chord similar to Cmd+K W:
-- always keeps the buffer you are editing in the active window; never deletes the current buffer.
-- Also keeps: NvimTree, terminals (toggleterm, etc.), Cursor/Claude agent terminals, help, quickfix, etc.

local M = {}

--- Buffer numbers that must never be deleted (agent terminals stored in vim.g).
local function protected_bufnrs()
  local out = {}
  for _, key in ipairs({ "cursor_agent_bufnr", "claude_agent_bufnr" }) do
    local n = vim.g[key]
    if type(n) == "number" and vim.api.nvim_buf_is_valid(n) then
      out[n] = true
    end
  end
  return out
end

--- True if this buffer is a normal editable file buffer we may close.
local function is_closable_file_buffer(bufnr, protected)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if protected[bufnr] then
    return false
  end
  local bo = vim.bo[bufnr]
  -- Only "normal" buffers (actual file / [No Name] editing), not terminal/help/qf/nofile.
  if bo.buftype ~= "" then
    return false
  end
  if not bo.buflisted then
    return false
  end
  local ft = bo.filetype
  if ft == "NvimTree" or ft == "help" or ft == "qf" then
    return false
  end
  return true
end

---@param opts? { force?: boolean } force=true discards unsaved changes in closed buffers (like :bd!).
function M.close_other_file_buffers(opts)
  opts = opts or {}
  local force = opts.force == true

  -- Active buffer: never closed (same idea as IDE "close all other tabs").
  local cur = vim.api.nvim_get_current_buf()
  local protected = protected_bufnrs()
  local to_close = {}

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= cur and is_closable_file_buffer(buf, protected) then
      to_close[#to_close + 1] = buf
    end
  end

  local delete_opts = force and { force = true } or {}
  local closed, failed = 0, 0
  for _, buf in ipairs(to_close) do
    local ok = pcall(vim.api.nvim_buf_delete, buf, delete_opts)
    if ok then
      closed = closed + 1
    else
      failed = failed + 1
    end
  end

  local active_label = vim.fn.bufname(cur)
  if active_label == "" then
    active_label = "[No Name]"
  end

  local mode = force and " (!)" or ""

  if failed > 0 then
    vim.notify(
      ("buffer_only%s: closed %d other buffer(s), %d skipped (protected). Active kept: %s"):format(
        mode,
        closed,
        failed,
        active_label
      ),
      vim.log.levels.WARN
    )
  elseif closed > 0 then
    vim.notify(
      ("buffer_only%s: closed %d other file buffer(s). Active buffer unchanged: %s"):format(mode, closed, active_label),
      vim.log.levels.INFO
    )
  else
    vim.notify(("buffer_only%s: nothing to close (active: %s)"):format(mode, active_label), vim.log.levels.INFO)
  end
end

return M
