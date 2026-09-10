local M = {}

local defaults = {
  "*.md",
  "*_test.go",
  "*_gen.go",
}

function M.config_path()
  return vim.g.luanphan_search_deprioritize_path
    or (vim.fn.stdpath("data") .. "/search-deprioritize")
end

function M.ensure_config(path)
  path = path or M.config_path()
  if vim.fn.filereadable(path) == 1 then
    return path
  end

  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ok, err = pcall(vim.fn.writefile, defaults, path)
  if not ok then
    vim.notify("Could not create search priority file: " .. tostring(err), vim.log.levels.WARN)
  end
  return path
end

function M.read_patterns(path)
  path = M.ensure_config(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    vim.notify("Could not read search priority file: " .. tostring(lines), vim.log.levels.WARN)
    lines = defaults
  end

  local patterns = {}
  for _, line in ipairs(lines) do
    local pattern = vim.trim(line)
    if pattern ~= "" and not vim.startswith(pattern, "#") then
      patterns[#patterns + 1] = {
        glob = pattern,
        regex = vim.fn.glob2regpat(pattern),
      }
    end
  end
  return patterns
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

function M.wrap_sorter(base, patterns)
  patterns = patterns or M.read_patterns()
  local sorters = require("telescope.sorters")
  local highlighter
  if base.highlighter then
    highlighter = function(_, prompt, display)
      return base.highlighter(base, prompt, display)
    end
  end

  return sorters.Sorter:new({
    discard = base.discard,
    highlighter = highlighter,
    scoring_function = function(_, prompt, line, entry, cb_add, cb_filter)
      local score = base.scoring_function(base, prompt, line, entry, cb_add, cb_filter)
      if score == nil or score < 0 then
        return score
      end
      return M.rank_path(entry_path(entry, line), patterns) * 10 + score
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
    title = " Search Deprioritize ",
    title_pos = "center",
  })

  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "gitignore"
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
