local M = {}

local DEFAULT_MAX_CACHE_ENTRY = 5
local DIFF_REPO_IGNORE_SECTION = "diff-repo-ignore"
local AGENT_FLOAT_SECTION = "agent_float"
local DEFAULT_AGENT_FLOAT = {
  display_style = "tabs",
  window_bar_style = "vertical",
  total_width_percent = 90,
  sidebar_width_percent = 31,
  terminal_width_percent = 69,
}
local TERMINAL_DEFAULTS = {
  floating_terminal = {
    display_style = "tile",
    window_bar_style = "vertical",
    backend = "tmux",
    total_width_percent = 100,
    sidebar_width_percent = 25,
    terminal_width_percent = 75,
  },
  terminal_split = { display_style = "tabs", window_bar_style = "horizontal" },
}
local TERMINAL_RECORD_SECTION = "terminal_record"
local DEFAULT_TERMINAL_RECORD = { enabled = true, max_mb = 64 }
local DISPLAY_STYLE_SETTING = 'display_style = "' .. DEFAULT_AGENT_FLOAT.display_style .. '"'

local function floating_width_lines(configured)
  local lines = {}
  for _, key in ipairs({ "total_width_percent", "sidebar_width_percent", "terminal_width_percent" }) do
    if not configured[key] then lines[#lines + 1] = key .. " = " .. TERMINAL_DEFAULTS.floating_terminal[key] end
  end
  return lines
end

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
  local headings, floating_widths = {}, {}
  local section, agent_float_line, has_display_style, has_bar_style, floating_end
  for index, line in ipairs(lines) do
    local value = vim.trim(line:gsub("#.*$", ""))
    headings[value] = true
    if value:match("^%[") then
      section = value
      if section == "[" .. AGENT_FLOAT_SECTION .. "]" then agent_float_line = index end
      if section == "[floating_terminal]" then floating_end = index end
    elseif section == "[" .. AGENT_FLOAT_SECTION .. "]" then
      has_display_style = has_display_style or value:match("^display_style%s*=")
      has_bar_style = has_bar_style or value:match("^window_bar_style%s*=")
    elseif section == "[floating_terminal]" and value ~= "" then
      floating_end = index
      local key = value:match("^([%w_]+)%s*=")
      if key then floating_widths[key] = true end
    end
  end
  local changed = not exists
  local additions = {}
  if agent_float_line then
    local fields = {}
    if not has_display_style then fields[#fields + 1] = DISPLAY_STYLE_SETTING end
    if not has_bar_style then fields[#fields + 1] = 'window_bar_style = "vertical"' end
    additions[agent_float_line] = fields
  end
  if floating_end then additions[floating_end] = floating_width_lines(floating_widths) end
  for index = #lines, 1, -1 do
    local fields = additions[index] or {}
    for field = #fields, 1, -1 do
      table.insert(lines, index + 1, fields[field])
      changed = true
    end
  end
  local sections = {
    { "[" .. DIFF_REPO_IGNORE_SECTION .. "]", "repositories = []" },
    {
      "[" .. AGENT_FLOAT_SECTION .. "]",
      '# Display style: "tabs" or "tile".',
      DISPLAY_STYLE_SETTING,
      'window_bar_style = "vertical"',
      "# Percentage of the editor width.",
      "total_width_percent = " .. DEFAULT_AGENT_FLOAT.total_width_percent,
      "# Percentages of the total float width. Unused width becomes the gap.",
      "sidebar_width_percent = " .. DEFAULT_AGENT_FLOAT.sidebar_width_percent,
      "terminal_width_percent = " .. DEFAULT_AGENT_FLOAT.terminal_width_percent,
    },
  }
  sections[#sections + 1] = {
    "[" .. TERMINAL_RECORD_SECTION .. "]",
    "# Keep recent tmux terminal output in memory; :TerminalRecordDump writes it to a file.",
    "enabled = " .. tostring(DEFAULT_TERMINAL_RECORD.enabled),
    "max_mb = " .. DEFAULT_TERMINAL_RECORD.max_mb,
  }
  for _, name in ipairs({ "floating_terminal", "terminal_split" }) do
    local defaults = TERMINAL_DEFAULTS[name]
    local block = {
      "[" .. name .. "]",
      'display_style = "' .. defaults.display_style .. '"',
      'window_bar_style = "' .. defaults.window_bar_style .. '"',
      defaults.backend and ('backend = "' .. defaults.backend .. '"') or nil,
    }
    if name == "floating_terminal" then vim.list_extend(block, floating_width_lines({})) end
    sections[#sections + 1] = block
  end
  for _, section in ipairs(sections) do
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

-- Layout code reads settings on every relayout, so parse the file only when it changes.
local cache = {}

local function file_stamp(path)
  local stat = vim.uv.fs_stat(path)
  return stat and ("%d.%d:%d:%d"):format(stat.mtime.sec, stat.mtime.nsec, stat.size, stat.ino)
end

function M.read(path)
  path = path or M.config_path()
  local cached = cache[path]
  if cached and cached.stamp == file_stamp(path) then return vim.deepcopy(cached.layout) end
  path = M.ensure_config(path)
  local layout = vim.deepcopy(TERMINAL_DEFAULTS)
  layout[AGENT_FLOAT_SECTION] = vim.deepcopy(DEFAULT_AGENT_FLOAT)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then lines = {} end

  local section
  local max_cache_entry = DEFAULT_MAX_CACHE_ENTRY
  local terminal_record = vim.deepcopy(DEFAULT_TERMINAL_RECORD)
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
    elseif section == TERMINAL_RECORD_SECTION then
      local enabled = value:match("^enabled%s*=%s*(%a+)$")
      if enabled == "true" or enabled == "false" then terminal_record.enabled = enabled == "true" end
      local megabytes = tonumber(value:match("^max_mb%s*=%s*([%d.]+)$"))
      if megabytes and megabytes > 0 then terminal_record.max_mb = megabytes end
    elseif layout[section] then
      local settings = layout[section]
      local key, raw = value:match("^([%w_]+)%s*=%s*([%d.]+)$")
      local percent = tonumber(raw)
      if type(settings[key]) == "number" and percent and percent >= 1 and percent <= 100 then
        settings[key] = percent
      end
      local name, style = value:match('^([%w_]+)%s*=%s*"([%a]+)"$')
      if not name then name, style = value:match("^([%w_]+)%s*=%s*'([%a]+)'$") end
      if name == "display_style" and (style == "tile" or style == "tabs") then settings[name] = style end
      if name == "backend" and settings.backend and (style == "tmux" or style == "shell") then settings.backend = style end
      if name == "window_bar_style" and (style == "vertical" or style == "horizontal") then settings[name] = style end
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

  layout.recent_folder = { max_cache_entry = max_cache_entry }
  layout.terminal_record = terminal_record
  layout.diff_repo_ignore = { repositories = ignored_repositories }
  cache[path] = { stamp = file_stamp(path), layout = layout }
  return vim.deepcopy(layout)
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
