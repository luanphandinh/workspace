-- LSP hard restart using |vim.lsp.enable()| disable/enable (Neovim 0.11+).
-- See :help lsp-restart — more reliable than stop_client + FileType alone.

local M = {}

--- Unique client.name list, optionally only clients attached to {bufnr}.
---@param bufnr integer|nil
---@return string[]
local function client_names(bufnr)
  local filter = bufnr and { bufnr = bufnr } or nil
  local clients = vim.lsp.get_clients(filter)
  local seen = {}
  local out = {}
  for _, c in ipairs(clients) do
    if not seen[c.name] then
      seen[c.name] = true
      out[#out + 1] = c.name
    end
  end
  return out
end

--- Disable then re-enable named configs (restarts those language servers project-wide).
---@param names string[]
function M.restart_servers(names)
  if #names == 0 then
    return false
  end
  for _, name in ipairs(names) do
    vim.lsp.enable(name, false)
  end
  vim.schedule(function()
    for _, name in ipairs(names) do
      vim.lsp.enable(name, true)
    end
  end)
  return true
end

--- Re-fire FileType on buffers so |nvim.lsp.enable| FileType hook runs again.
---@param bufnr integer|nil if set, only this buffer; otherwise all loaded normal buffers
local function refire_filetype(bufnr)
  if bufnr then
    vim.api.nvim_exec_autocmds("FileType", { buffer = bufnr })
    return
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == "" then
      vim.api.nvim_exec_autocmds("FileType", { buffer = b })
    end
  end
end

--- Restart every distinct LSP that is currently running.
function M.restart_all()
  local names = client_names(nil)
  if #names == 0 then
    vim.notify("No LSP clients running; re-triggering FileType on buffers", vim.log.levels.INFO)
    refire_filetype(nil)
    return
  end
  M.restart_servers(names)
  vim.notify("LSP restarted: " .. table.concat(names, ", "), vim.log.levels.INFO)
end

--- Restart LSPs attached to the current buffer (same as full restart for shared servers like gopls).
--- If none attached, re-triggers FileType on this buffer only (recovery when attach failed).
function M.restart_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  local names = client_names(bufnr)
  if #names == 0 then
    vim.notify("No LSP on this buffer; re-triggering FileType", vim.log.levels.WARN)
    refire_filetype(bufnr)
    return
  end
  M.restart_servers(names)
  vim.notify("LSP restarted for buffer: " .. table.concat(names, ", "), vim.log.levels.INFO)
end

vim.api.nvim_create_user_command("LspRestart", function()
  M.restart_all()
end, { desc = "Disable+re-enable all running LSP clients (full restart)" })

vim.api.nvim_create_user_command("LspRestartBuffer", function()
  M.restart_buffer()
end, { desc = "Restart LSP for current buffer (or re-trigger FileType if none)" })

return M
