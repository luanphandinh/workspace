-- LSP full restart: |client:stop()| + |vim.lsp.enable(false/true)| (Neovim 0.11+), then re-fire
-- FileType on buffers so each server attaches again. See :help lsp-restart.

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

--- True if |vim.lsp.config()| was used for this server (managed by |vim.lsp.enable()|).
---@param name string
local function has_registered_config(name)
  return vim.lsp.config[name] ~= nil
end

--- Servers started with |vim.lsp.start()| only (e.g. github/copilot.vim) — no vim.lsp.config entry.
--- Calling |vim.lsp.enable(name, true)| for them adds a bogus _enabled_configs slot and triggers
--- "config not found" in :checkhealth; each enable(true) also runs doautoall (duplicate gopls).
---@param name string
local function restart_plugin_lsp(name)
  if name == "GitHub Copilot" then
    pcall(vim.cmd, "Copilot restart")
  end
end

--- Re-fire FileType on buffers so LSP attach runs again (recovers buffers left without a client).
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

---@param names string[]
---@return string[]
local function managed_names(names)
  local out = {}
  for _, name in ipairs(names) do
    if has_registered_config(name) then
      out[#out + 1] = name
    end
  end
  return out
end

--- After stops + enable(false): re-enable managed servers, wait for processes, refire FileType,
--- restart plugin LSPs (Copilot), optional notify.
---@param managed string[]
---@param names string[] all server names in this restart (for plugin restarts)
---@param opts { on_done?: fun() }|nil
local function schedule_reenable_refire(managed, names, opts)
  vim.defer_fn(function()
    if #managed > 0 then
      vim.lsp.enable(managed, true)
    end
    vim.defer_fn(function()
      refire_filetype(nil)
      for _, name in ipairs(names) do
        if not has_registered_config(name) then
          restart_plugin_lsp(name)
        end
      end
      if opts and opts.on_done then
        opts.on_done()
      end
    end, 150)
  end, 50)
end

--- Stop clients for {names}, cycle enable for managed configs, then re-attach on all normal buffers.
---@param names string[]
---@param opts { on_done?: fun() }|nil
function M.restart_servers(names, opts)
  if #names == 0 then
    return false
  end

  local managed = managed_names(names)

  for _, name in ipairs(names) do
    for _, client in ipairs(vim.lsp.get_clients({ name = name })) do
      client:stop()
    end
  end

  if #managed > 0 then
    vim.lsp.enable(managed, false)
  end

  schedule_reenable_refire(managed, names, opts)
  return true
end

--- Stop every LSP client, re-enable every managed server that was running, refire FileType on buffers.
function M.restart_all()
  local names = client_names(nil)
  if #names == 0 then
    vim.notify("No LSP clients running; re-triggering FileType on buffers", vim.log.levels.INFO)
    refire_filetype(nil)
    return
  end

  local managed = managed_names(names)

  for _, client in ipairs(vim.lsp.get_clients()) do
    client:stop()
  end

  if #managed > 0 then
    vim.lsp.enable(managed, false)
  end

  schedule_reenable_refire(managed, names, {
    on_done = function()
      vim.notify("LSP restarted: " .. table.concat(names, ", "), vim.log.levels.INFO)
    end,
  })
end

--- Full gopls-only restart (same pipeline as |restart_servers|, convenience mapping).
function M.restart_gopls()
  if not has_registered_config("gopls") then
    vim.notify("gopls is not registered (vim.lsp.config)", vim.log.levels.WARN)
    return
  end
  M.restart_servers({ "gopls" }, {
    on_done = function()
      vim.notify("gopls restarted; re-attached on open buffers", vim.log.levels.INFO)
    end,
  })
end

--- Restart LSPs attached to the current buffer. Shared servers (e.g. gopls) get a full stop + all buffers refired.
--- If none attached, re-triggers FileType on this buffer only (recovery when attach failed).
function M.restart_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  local names = client_names(bufnr)
  if #names == 0 then
    vim.notify("No LSP on this buffer; re-triggering FileType", vim.log.levels.WARN)
    refire_filetype(bufnr)
    return
  end
  M.restart_servers(names, {
    on_done = function()
      vim.notify("LSP restarted for buffer: " .. table.concat(names, ", "), vim.log.levels.INFO)
    end,
  })
end

vim.api.nvim_create_user_command("LspRestart", function()
  M.restart_all()
end, { desc = "Stop all LSP clients, re-enable, re-attach on open buffers" })

vim.api.nvim_create_user_command("LspRestartBuffer", function()
  M.restart_buffer()
end, { desc = "Restart LSP for current buffer (or re-trigger FileType if none)" })

vim.api.nvim_create_user_command("GoplsRestart", function()
  M.restart_gopls()
end, { desc = "Stop gopls, re-enable, re-attach on all open Go buffers" })

return M
