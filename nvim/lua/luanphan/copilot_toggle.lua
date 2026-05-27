-- Lazy-load github/copilot.vim (opt) on first <leader>tc, then start it in the background.
-- Further <leader>tc toggles suggestions on/off without cold-restarting the GitHub Copilot LSP.
--
-- If the plugin loads after |VimEnter|, the plugin's own VimEnter autocmd never runs, so
-- |copilot#Init()| must be invoked manually or the language server never starts.

local M = {}

local function copilot_cmd_exists()
  return vim.fn.exists(":Copilot") == 2
end

local function redraw_statusline()
  pcall(vim.cmd, "redrawstatus")
end

local function copilot_globally_on()
  return vim.g.copilot_enabled ~= 0
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
    redraw_statusline()
    vim.schedule(function()
      copilot_init_if_needed()
      vim.notify("Copilot: loaded; starting in background", vim.log.levels.INFO)
      redraw_statusline()
    end)
    return
  end

  if copilot_globally_on() then
    pcall(vim.cmd, "Copilot disable")
    vim.notify("Copilot: disabled", vim.log.levels.INFO)
  else
    vim.cmd("Copilot enable")
    copilot_init_if_needed()
    vim.notify("Copilot: enabled", vim.log.levels.INFO)
  end
  redraw_statusline()
end

function M.statusline()
  if not copilot_cmd_exists() then
    return ""
  end
  return copilot_globally_on() and "cp:on" or "cp:off"
end

return M
