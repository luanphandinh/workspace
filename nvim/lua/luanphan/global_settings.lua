local M = {}

local DEFAULT_MAX_CACHE_ENTRY = 5
local DIFF_REPO_IGNORE_SECTION = "diff-repo-ignore"

function M.config_path()
  return vim.g.luanphan_global_settings_path
    or (vim.fn.stdpath("data") .. "/global-settings.toml")
end

local function default_lines()
  return {
    "[recent_folder]",
    "max_cache_entry = " .. DEFAULT_MAX_CACHE_ENTRY,
    "",
    "[" .. DIFF_REPO_IGNORE_SECTION .. "]",
    "repositories = []",
  }
end

function M.ensure_config(path)
  path = path or M.config_path()
  if vim.fn.filereadable(path) == 1 then
    local lines = vim.fn.readfile(path)
    for _, line in ipairs(lines) do
      if vim.trim(line:gsub("#.*$", "")) == "[" .. DIFF_REPO_IGNORE_SECTION .. "]" then
        return path
      end
    end
    if #lines > 0 and lines[#lines] ~= "" then
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = "[" .. DIFF_REPO_IGNORE_SECTION .. "]"
    lines[#lines + 1] = "repositories = []"
    local ok, err = pcall(vim.fn.writefile, lines, path)
    if not ok then
      vim.notify("Could not update global settings: " .. tostring(err), vim.log.levels.WARN)
    end
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
    return {
      recent_folder = { max_cache_entry = DEFAULT_MAX_CACHE_ENTRY },
      diff_repo_ignore = { repositories = {} },
    }
  end

  local section
  local max_cache_entry = DEFAULT_MAX_CACHE_ENTRY
  local ignored_repositories = {}
  local reading_ignored_repositories = false
  for _, line in ipairs(lines) do
    local value = vim.trim(line:gsub("#.*$", ""))
    local heading = value:match("^%[([^%]]+)%]$")
    if heading then
      section = heading
      reading_ignored_repositories = false
    elseif section == "recent_folder" then
      local configured = value:match("^max_cache_entry%s*=%s*(%d+)%s*$")
      configured = tonumber(configured)
      if configured and configured >= 1 then
        max_cache_entry = math.floor(configured)
      end
    elseif section == DIFF_REPO_IGNORE_SECTION then
      local array = reading_ignored_repositories and value
        or value:match("^repositories%s*=%s*(%[.*)$")
      if array then
        for repository in array:gmatch('"([^"]+)"') do
          ignored_repositories[#ignored_repositories + 1] = repository
        end
        for repository in array:gmatch("'([^']+)'") do
          ignored_repositories[#ignored_repositories + 1] = repository
        end
        reading_ignored_repositories = not array:find("%]")
      end
    end
  end

  return {
    recent_folder = { max_cache_entry = max_cache_entry },
    diff_repo_ignore = { repositories = ignored_repositories },
  }
end

function M.max_recent_folders(path)
  return M.read(path).recent_folder.max_cache_entry
end

function M.diff_repo_ignores(path)
  return M.read(path).diff_repo_ignore.repositories
end

function M.open_editor()
  require("luanphan.settings_editor").open(M.ensure_config(), {
    title = "Global Settings",
    filetype = "toml",
  })
end

return M
