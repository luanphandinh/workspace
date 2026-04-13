-- Lazy-load github/copilot.vim (opt) on first <leader>tc, then :Copilot status (not enable).
-- Further <leader>tc toggles enable/disable as usual.
--
-- If the plugin loads after |VimEnter|, the plugin's own VimEnter autocmd never runs, so
-- |copilot#Init()| must be invoked manually or the language server never starts.

local M = {}

local function copilot_cmd_exists()
  return vim.fn.exists(":Copilot") == 2
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

local function copilot_on()
  local v = vim.g.copilot_enabled
  if v == nil then
    return true
  end
  return v ~= 0 and v ~= false
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

  if copilot_on() then
    vim.cmd("Copilot disable")
    vim.notify("Copilot: disabled (this session)", vim.log.levels.INFO)
  else
    copilot_init_if_needed()
    vim.cmd("Copilot enable")
    vim.notify("Copilot: enabled", vim.log.levels.INFO)
  end
end

return M
