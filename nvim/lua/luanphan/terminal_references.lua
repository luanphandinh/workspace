local M = {}

local namespace = vim.api.nvim_create_namespace("LuanphanTerminalReferences")
local attached = {}
local tracked = {}
local enabled = vim.g.luanphan_terminal_reference_links_enabled ~= false
  and vim.g.luanphan_terminal_reference_links_enabled ~= 0
vim.g.luanphan_terminal_reference_links_enabled = enabled

local function resolve_path(cwd, value)
  value = value:gsub("^@", "")
  local path
  if value:sub(1, 1) == "~" then
    path = vim.fn.expand(value)
  elseif vim.fn.isabsolutepath(value) == 1 then
    path = value
  else
    path = cwd .. "/" .. value
  end
  path = vim.fs.normalize(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  return path
end

local function references_in_line(cwd, text)
  local result = {}
  local offset = 1
  while offset <= #text do
    local first, last = text:find("[@~%w%._%-%+/]+:%d+:?%d*", offset)
    if not first then
      break
    end

    local value = text:sub(first, last)
    local raw_path, line, column = value:match("^@?(.-):(%d+):?(%d*)$")
    local path = raw_path and resolve_path(cwd, raw_path) or nil
    local line_number = tonumber(line)
    local column_number = tonumber(column) or 1
    if path and line_number then
      result[#result + 1] = {
        first_col = first - 1,
        last_col = last,
        path = path,
        line = line_number,
        column = column_number,
      }
    end
    offset = last + 1
  end
  return result
end

local function wrapped_reference(cwd, first_text, second_text)
  local first_col, first_end, first_path = first_text:find("([@~%w%._%-%+/]+)$")
  if not first_path or not first_path:find("/", 1, true) then
    return nil
  end

  local _, second_end, second_path, line, column = second_text:find("^%s*([@~%w%._%-%+/]+):(%d+):?(%d*)")
  if not second_path then
    return nil
  end

  local path = resolve_path(cwd, first_path .. second_path)
  local line_number = tonumber(line)
  local column_number = tonumber(column) or 1
  if not path or not line_number then
    return nil
  end

  local second_col = second_text:find(second_path, 1, true)
  return {
    first = {
      first_col = first_col - 1,
      last_col = first_end,
      path = path,
      line = line_number,
      column = column_number,
    },
    second = {
      first_col = second_col - 1,
      last_col = second_end,
      path = path,
      line = line_number,
      column = column_number,
    },
  }
end

local function target_at(bufnr, row, column)
  if not enabled or not attached[bufnr] or row < 0 or column < 0 then
    return nil
  end

  local cwd = tracked[bufnr]
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if not cwd or row >= line_count then
    return nil
  end

  local function line_at(index)
    if index < 0 or index >= line_count then
      return nil
    end
    return vim.api.nvim_buf_get_lines(bufnr, index, index + 1, false)[1]
  end

  local function contains(reference)
    return reference
      and column >= reference.first_col
      and column < reference.last_col
  end

  local function target(reference)
    return {
      path = reference.path,
      line = reference.line,
      column = reference.column,
    }
  end

  local current = line_at(row) or ""
  for _, reference in ipairs(references_in_line(cwd, current)) do
    if contains(reference) then
      return target(reference)
    end
  end

  local next_line = line_at(row + 1)
  if next_line then
    local wrapped = wrapped_reference(cwd, current, next_line)
    if wrapped and contains(wrapped.first) then
      return target(wrapped.first)
    end
  end

  local previous = line_at(row - 1)
  if previous then
    local wrapped = wrapped_reference(cwd, previous, current)
    if wrapped and contains(wrapped.second) then
      return target(wrapped.second)
    end
  end
  return nil
end

local function handle_mouse_click(bufnr)
  local mouse = vim.fn.getmousepos()
  if not mouse or not mouse.winid or not vim.api.nvim_win_is_valid(mouse.winid) then
    return "<M-LeftMouse>"
  end
  if vim.api.nvim_win_get_buf(mouse.winid) ~= bufnr then
    return "<M-LeftMouse>"
  end

  local target = target_at(bufnr, (mouse.line or 0) - 1, (mouse.column or 0) - 1)
  if not target then
    return "<M-LeftMouse>"
  end

  vim.schedule(function()
    if vim.api.nvim_win_is_valid(mouse.winid) then
      vim.api.nvim_set_current_win(mouse.winid)
      M.open(target.path, target.line, target.column)
    end
  end)
  return "<Ignore>"
end

local function set_click_keymaps(bufnr)
  local opts = {
    buffer = bufnr,
    expr = true,
    silent = true,
    desc = "Open terminal file reference",
  }
  for _, mode in ipairs({ "n", "t" }) do
    vim.keymap.set(mode, "<M-LeftMouse>", function()
      return handle_mouse_click(bufnr)
    end, opts)
  end
end

function M.attach(bufnr, cwd)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  cwd = vim.fs.normalize(cwd)
  tracked[bufnr] = cwd
  vim.b[bufnr].luanphan_terminal_reference_cwd = cwd
  set_click_keymaps(bufnr)

  if attached[bufnr] then
    return namespace
  end
  attached[bufnr] = true
  vim.api.nvim_buf_attach(bufnr, false, {
    on_detach = function(_, detached_bufnr)
      attached[detached_bufnr] = nil
      tracked[detached_bufnr] = nil
    end,
  })
  return namespace
end

function M.activate() end

function M.is_enabled()
  return enabled
end

function M.set_enabled(value, silent)
  enabled = value == true
  vim.g.luanphan_terminal_reference_links_enabled = enabled

  if not silent then
    vim.notify("Terminal reference links " .. (enabled and "enabled" or "disabled"))
  end
  return enabled
end

function M.toggle()
  return M.set_enabled(not enabled)
end

local function is_editor_window(win)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local config = vim.api.nvim_win_get_config(win)
  if config.relative and config.relative ~= "" then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.bo[buf].buftype == "" and vim.bo[buf].filetype ~= "NvimTree"
end

local function find_editor_window(source)
  local previous = vim.fn.win_getid(vim.fn.winnr("#"))
  if previous ~= source and is_editor_window(previous) then
    return previous
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= source and is_editor_window(win) then
      return win
    end
  end
  return nil
end

function M.open(path, line, column)
  path = vim.fs.normalize(path)
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("Reference file not found: " .. path, vim.log.levels.ERROR)
    return false
  end

  local source = vim.api.nvim_get_current_win()
  local source_buf = vim.api.nvim_win_get_buf(source)
  local source_config = vim.api.nvim_win_get_config(source)
  local close_agent_float = source_config.relative ~= ""
    and vim.bo[source_buf].buftype == "terminal"
    and vim.b[source_buf].luanphan_persist_term
  local target = find_editor_window(source)

  if not target and close_agent_float then
    vim.api.nvim_win_close(source, false)
    source = nil
    target = find_editor_window(-1)
  end
  if not target then
    vim.cmd("new")
    target = vim.api.nvim_get_current_win()
  else
    vim.api.nvim_set_current_win(target)
  end

  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local last_line = vim.api.nvim_buf_line_count(0)
  local target_line = math.max(1, math.min(tonumber(line) or 1, last_line))
  local target_column = math.max(0, (tonumber(column) or 1) - 1)
  vim.api.nvim_win_set_cursor(target, { target_line, target_column })

  if close_agent_float and source and vim.api.nvim_win_is_valid(source) then
    vim.api.nvim_win_close(source, false)
  end
  return true
end

return M
