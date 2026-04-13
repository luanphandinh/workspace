-- Lazy-load github/copilot.vim (opt) on first <leader>tc, then :Copilot status (not enable).
-- Further <leader>tc toggles enable/disable; "off" stops the GitHub Copilot LSP (|vim.lsp|).
-- Re-enable after that runs :Copilot restart so copilot.vim clears stale |s:client| (startup_error deadlock).
--
-- If the plugin loads after |VimEnter|, the plugin's own VimEnter autocmd never runs, so
-- |copilot#Init()| must be invoked manually or the language server never starts.

local M = {}

--- After |vim.lsp.stop_client()|, copilot.vim can leave a stale |s:client| with |startup_error| set,
--- so |s:Start()| refuses to spawn again. :Copilot restart runs |s:Stop()| then |s:Start()| and fixes that.
local needs_copilot_restart = false

--- github/copilot.vim registers this name with |vim.lsp.start()| (see copilot#client#New).
local COPILOT_LSP_NAME = "GitHub Copilot"

local function copilot_cmd_exists()
  return vim.fn.exists(":Copilot") == 2
end

--- Kill the Copilot language server process (|:Copilot disable| does not stop the Node LS).
local function stop_copilot_lsp()
  local clients = {}
  if vim.lsp.get_clients then
    local ok, res = pcall(vim.lsp.get_clients, { name = COPILOT_LSP_NAME })
    if ok and type(res) == "table" then
      clients = res
    end
  end
  if #clients == 0 and vim.lsp.get_active_clients then
    for _, c in ipairs(vim.lsp.get_active_clients()) do
      if c.name == COPILOT_LSP_NAME then
        clients[#clients + 1] = c
      end
    end
  end
  for _, client in ipairs(clients) do
    pcall(function()
      if client.stop then
        client:stop()
      elseif client.id then
        vim.lsp.stop_client(client.id)
      end
    end)
  end
end

--- Start LSP client when Copilot was loaded after VimEnter (lazy opt load).
local function copilot_init_if_needed()
  pcall(vim.cmd, "call copilot#Init()")
end

---@return boolean ok
---@return string|nil err
local function load_copilot_plugin()
  local last_err
  local ok, err = pcall(function()
    require("packer").loader("copilot.vim")
  end)
  if not ok then
    last_err = tostring(err)
  end
  if not copilot_cmd_exists() then
    ok, err = pcall(vim.cmd, "packadd copilot.vim")
    if not ok then
      last_err = last_err or tostring(err)
    end
  end
  if not copilot_cmd_exists() then
    return false, last_err or "packadd did not define :Copilot"
  end
  return true, nil
end

--- Delegates to |copilot#Enabled()| (plugin global + buffer/filetype gates).
local function copilot_effective_on()
  if not copilot_cmd_exists() then
    return false
  end
  local ok, v = pcall(vim.call, "copilot#Enabled")
  if not ok then
    return false
  end
  return v ~= 0
end

function M.toggle()
  if not copilot_cmd_exists() then
    local ok, err = load_copilot_plugin()
    if not ok then
      vim.notify(
        "Copilot: could not load — " .. (err or "?") .. " (run :PackerSync if the plugin is missing)",
        vim.log.levels.ERROR
      )
      return
    end
    vim.schedule(function()
      copilot_init_if_needed()
      local st_ok, st_err = pcall(vim.cmd, "Copilot status")
      if not st_ok then
        vim.notify("Copilot: " .. tostring(st_err), vim.log.levels.ERROR)
      end
      -- :Copilot status echoes Ready / issues; no extra notify
    end)
    return
  end

  if copilot_effective_on() then
    stop_copilot_lsp()
    pcall(vim.cmd, "Copilot disable")
    needs_copilot_restart = true
    vim.notify("Copilot: disabled; language server stopped", vim.log.levels.INFO)
  else
    vim.cmd("Copilot enable")
    if needs_copilot_restart then
      -- Must run after external LSP kill so plugin drops dead |s:client| (see file header).
      pcall(vim.cmd, "Copilot restart")
      needs_copilot_restart = false
    else
      copilot_init_if_needed()
    end
    vim.notify("Copilot: enabled", vim.log.levels.INFO)
  end
end

return M
