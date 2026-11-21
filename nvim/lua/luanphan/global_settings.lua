local M = {}

local DEFAULT_MAX_CACHE_ENTRY = 5
local DIFF_REPO_IGNORE_SECTION = "diff-repo-ignore"
local AGENT_FLOAT_SECTION = "agent_float"
local DEFAULT_AGENT_FLOAT = {
  display_style = "tabs",
  total_width_percent = 90,
  sidebar_width_percent = 31,
  terminal_width_percent = 69,
}
local DISPLAY_STYLE_SETTING = 'display_style = "' .. DEFAULT_AGENT_FLOAT.display_style .. '"'

function M.config_path()
  return vim.g.luanphan_global_settings_path
    or (vim.fn.stdpath("data") .. "/global-settings.toml")
end

function M.ensure_config(path)
  path = path or M.config_path()
  local exists = vim.fn.filereadable(path) == 1
  local lines = exists and vim.fn.readfile(path) or {
    "[recent_folder]", "max_cache_entry = " .. DEFAULT_MAX_CACHE_ENTRY,
  }
  local headings = {}
  local in_agent_float, agent_float_line, has_display_style
  for index, line in ipairs(lines) do
    local value = vim.trim(line:gsub("#.*$", ""))
    headings[value] = true
    if value:match("^%[") then
      in_agent_float = value == "[" .. AGENT_FLOAT_SECTION .. "]"
      if in_agent_float then agent_float_line = index end
    elseif in_agent_float and value:match("^display_style%s*=") then
      has_display_style = true
    end
  end
  local changed = not exists
  if agent_float_line and not has_display_style then
    table.insert(lines, agent_float_line + 1, DISPLAY_STYLE_SETTING)
    changed = true
  end
  for _, section in ipairs({
    { "[" .. DIFF_REPO_IGNORE_SECTION .. "]", "repositories = []" },
    {
      "[" .. AGENT_FLOAT_SECTION .. "]",
      '# Display style: "tabs" or "tile".',
      DISPLAY_STYLE_SETTING,
      "# Percentage of the editor width.",
      "total_width_percent = " .. DEFAULT_AGENT_FLOAT.total_width_percent,
      "# Percentages of the total float width. Unused width becomes the gap.",
      "sidebar_width_percent = " .. DEFAULT_AGENT_FLOAT.sidebar_width_percent,
      "terminal_width_percent = " .. DEFAULT_AGENT_FLOAT.terminal_width_percent,
    },
  }) do
    if not headings[section[1]] then
      if #lines > 0 and lines[#lines] ~= "" then lines[#lines + 1] = "" end
      vim.list_extend(lines, section)
      changed = true
    end
  end
  if changed then
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local ok, result = pcall(vim.fn.writefile, lines, path)
    if not ok or result ~= 0 then
      vim.notify("Could not write global settings: " .. tostring(result), vim.log.levels.WARN)
    end
  end
  return path
end

function M.read(path)
  path = M.ensure_config(path)
  local agent_float = vim.deepcopy(DEFAULT_AGENT_FLOAT)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return {
      recent_folder = { max_cache_entry = DEFAULT_MAX_CACHE_ENTRY },
      diff_repo_ignore = { repositories = {} },
      agent_float = agent_float,
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
    elseif section == AGENT_FLOAT_SECTION then
      local key, raw = value:match("^([%w_]+)%s*=%s*([%d.]+)$")
      local percent = tonumber(raw)
      if type(DEFAULT_AGENT_FLOAT[key]) == "number" and percent and percent >= 1 and percent <= 100 then
        agent_float[key] = percent
      end
      local style = value:match('^display_style%s*=%s*"([%a]+)"$')
        or value:match("^display_style%s*=%s*'([%a]+)'$")
      if style == "tile" or style == "tabs" then agent_float.display_style = style end
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
    agent_float = agent_float,
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
