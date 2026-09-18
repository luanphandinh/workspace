local M = {}

local default_deprioritize = {
  "*.md",
  "*_test.go",
  "*_gen.go",
}

local deprioritized_highlight = "LuanphanSearchDeprioritized"
local valid_sections = {
  deprioritize = true,
  ignore = true,
}

function M.config_path()
  return vim.g.luanphan_search_rules_path
    or (vim.fn.stdpath("data") .. "/search-rules.conf")
end

function M.legacy_config_path()
  return vim.g.luanphan_search_deprioritize_path
    or (vim.fn.stdpath("data") .. "/search-deprioritize")
end

local function pattern_lines(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, lines
  end

  local patterns = {}
  for _, line in ipairs(lines) do
    local pattern = vim.trim(line)
    if pattern ~= "" and not vim.startswith(pattern, "#") then
      patterns[#patterns + 1] = pattern
    end
  end
  return patterns
end

local function config_lines(deprioritize)
  local lines = { "[deprioritize]" }
  vim.list_extend(lines, deprioritize)
  vim.list_extend(lines, { "", "[ignore]" })
  return lines
end

function M.ensure_config(path, legacy_path)
  local default_path = path == nil
  path = path or M.config_path()
  if vim.fn.filereadable(path) == 1 then
    return path
  end

  if legacy_path == nil and default_path then
    legacy_path = M.legacy_config_path()
  end

  local deprioritize = default_deprioritize
  if legacy_path and vim.fn.filereadable(legacy_path) == 1 then
    local migrated, err = pattern_lines(legacy_path)
    if migrated then
      deprioritize = migrated
    else
      vim.notify("Could not migrate search settings: " .. tostring(err), vim.log.levels.WARN)
    end
  end

  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ok, err = pcall(vim.fn.writefile, config_lines(deprioritize), path)
  if not ok then
    vim.notify("Could not create search settings file: " .. tostring(err), vim.log.levels.WARN)
  end
  return path
end

local function compile_pattern(pattern)
  return {
    glob = pattern,
    regex = vim.fn.glob2regpat(pattern),
  }
end

function M.read_rules(path, legacy_path)
  path = M.ensure_config(path, legacy_path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    vim.notify("Could not read search settings file: " .. tostring(lines), vim.log.levels.WARN)
    lines = config_lines(default_deprioritize)
  end

  local rules = { deprioritize = {}, ignore = {} }
  local section
  for line_number, line in ipairs(lines) do
    local value = vim.trim(line)
    local heading = value:match("^%[([^%]]+)%]$")
    if heading then
      section = valid_sections[heading] and heading or nil
      if not section then
        vim.notify(
          string.format("Unknown search settings section [%s] at line %d", heading, line_number),
          vim.log.levels.WARN
        )
      end
    elseif value ~= "" and not vim.startswith(value, "#") then
      if not section then
        vim.notify(string.format("Search pattern outside a section at line %d", line_number), vim.log.levels.WARN)
      elseif vim.startswith(value, "!") then
        vim.notify(string.format("Search pattern cannot start with ! at line %d", line_number), vim.log.levels.WARN)
      else
        rules[section][#rules[section] + 1] = compile_pattern(value)
      end
    end
  end
  return rules
end

function M.rank_path(path, patterns)
  path = (path or ""):gsub("\\", "/")
  for index, pattern in ipairs(patterns or {}) do
    if vim.fn.match(path, pattern.regex) >= 0 then
      return index
    end
  end
  return 0
end

local function entry_path(entry, line)
  if entry then
    return entry.filename or entry.path or entry.value or line
  end
  return line
end

function M.ignore_args(rules)
  rules = rules or M.read_rules()
  local args = {}
  for _, pattern in ipairs(rules.ignore or {}) do
    vim.list_extend(args, { "--glob", "!" .. pattern.glob })
  end
  return args
end

local function mute_entry(entry)
  local display = entry and entry.display
  if type(display) ~= "function" then
    return
  end

  entry.display = function(self, picker)
    local text, highlights = display(self, picker)
    if type(text) ~= "string" then
      return text, highlights
    end

    highlights = vim.list_extend({}, highlights or {})
    highlights[#highlights + 1] = { { 0, #text }, deprioritized_highlight }
    return text, highlights
  end
end

function M.wrap_sorter(base, rules)
  rules = rules or M.read_rules()
  local deprioritize = rules.deprioritize or {}
  local ignore = rules.ignore or {}
  local sorters = require("telescope.sorters")
  local states = setmetatable({}, { __mode = "k" })
  local styled = setmetatable({}, { __mode = "k" })
  local highlighter
  if base.highlighter then
    highlighter = function(_, prompt, display)
      return base.highlighter(base, prompt, display)
    end
  end

  vim.api.nvim_set_hl(0, deprioritized_highlight, { default = true, link = "Comment" })

  return sorters.Sorter:new({
    discard = base.discard,
    highlighter = highlighter,
    scoring_function = function(_, prompt, line, entry, cb_add, cb_filter)
      local state
      if type(entry) == "table" then
        state = states[entry]
      end
      if not state then
        local path = entry_path(entry, line)
        state = {
          ignored = M.rank_path(path, ignore) > 0,
          rank = M.rank_path(path, deprioritize),
        }
        if type(entry) == "table" then
          states[entry] = state
        end
      end
      if state.ignored then
        return -1
      end

      local score = base.scoring_function(base, prompt, line, entry, cb_add, cb_filter)
      if score == nil or score < 0 then
        return score
      end

      if state.rank > 0 and type(entry) == "table" and not styled[entry] then
        mute_entry(entry)
        styled[entry] = true
      end
      return state.rank * 10 + score
    end,
  })
end

function M.open_editor()
  local path = M.ensure_config()
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)

  local existing = vim.fn.bufwinid(buf)
  if existing ~= -1 then
    vim.api.nvim_set_current_win(existing)
    return
  end

  local width = math.max(40, math.floor(vim.o.columns * 0.5))
  local height = math.max(8, math.floor(vim.o.lines * 0.4))
  width = math.min(width, vim.o.columns - 4)
  height = math.min(height, vim.o.lines - 4)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "single",
    title = " Search Settings ",
    title_pos = "center",
  })

  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "dosini"
  vim.wo[win].number = true
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = false

  local closing = false
  local function save_and_close()
    if closing then
      return
    end

    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
      local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
        vim.cmd("silent write")
      end)
      if not ok then
        vim.notify("Could not save search priority file: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
    end

    closing = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.keymap.set("n", "q", save_and_close, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", save_and_close, { buffer = buf, silent = true })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = vim.api.nvim_create_augroup("LuanphanSearchPriorityEditor", { clear = false }),
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        if not closing and vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() ~= win then
          save_and_close()
        end
      end)
    end,
  })
end

return M
