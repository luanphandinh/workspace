local M = {}

local DEFAULT_MAX_CACHE_ENTRY = 5

function M.config_path()
  return vim.g.luanphan_global_settings_path
    or (vim.fn.stdpath("data") .. "/global-settings.toml")
end

local function default_lines()
  return {
    "[recent_folder]",
    "max_cache_entry = " .. DEFAULT_MAX_CACHE_ENTRY,
  }
end

function M.ensure_config(path)
  path = path or M.config_path()
  if vim.fn.filereadable(path) == 1 then
    return path
  end

  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ok, err = pcall(vim.fn.writefile, default_lines(), path)
  if not ok then
    vim.notify("Could not create global settings: " .. tostring(err), vim.log.levels.WARN)
  end
  return path
end

function M.read(path)
  path = M.ensure_config(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return { recent_folder = { max_cache_entry = DEFAULT_MAX_CACHE_ENTRY } }
  end

  local section
  local max_cache_entry = DEFAULT_MAX_CACHE_ENTRY
  for _, line in ipairs(lines) do
    local value = vim.trim(line:gsub("#.*$", ""))
    local heading = value:match("^%[([^%]]+)%]$")
    if heading then
      section = heading
    elseif section == "recent_folder" then
      local configured = value:match("^max_cache_entry%s*=%s*(%d+)%s*$")
      configured = tonumber(configured)
      if configured and configured >= 1 then
        max_cache_entry = math.floor(configured)
      end
    end
  end

  return { recent_folder = { max_cache_entry = max_cache_entry } }
end

function M.max_recent_folders(path)
  return M.read(path).recent_folder.max_cache_entry
end

function M.open_editor()
  require("luanphan.settings_editor").open(M.ensure_config(), {
    title = "Global Settings",
    filetype = "toml",
  })
end

return M
