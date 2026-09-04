local M = {}

local namespace = vim.api.nvim_create_namespace("LuanphanTerminalReferences")
local attached = {}
local pending = {}

local function encode(value)
  return tostring(value):gsub("([^%w%-._~])", function(char)
    return string.format("%%%02X", string.byte(char))
  end)
end

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

local function reference_url(path, line, column)
  local server = vim.v.servername
  if server == "" then
    return nil
  end
  return table.concat({
    "nvim-ref://open?server=", encode(server),
    "&path=", encode(path),
    "&line=", tostring(line),
    "&column=", tostring(column or 1),
  })
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
    local url = path and line_number and reference_url(path, line_number, column_number) or nil
    if url then
      result[#result + 1] = {
        first_col = first - 1,
        last_col = last,
        url = url,
      }
    end
    offset = last + 1
  end
  return result
end

local function refresh(bufnr, first_line, last_line)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local cwd = vim.b[bufnr].luanphan_terminal_reference_cwd
  if type(cwd) ~= "string" or cwd == "" then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  first_line = math.max(0, math.min(first_line or 0, line_count))
  last_line = math.max(first_line, math.min(last_line or line_count, line_count))
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, first_line, last_line)

  for index, text in ipairs(vim.api.nvim_buf_get_lines(bufnr, first_line, last_line, false)) do
    local row = first_line + index - 1
    for _, reference in ipairs(references_in_line(cwd, text)) do
      vim.api.nvim_buf_set_extmark(bufnr, namespace, row, reference.first_col, {
        end_col = reference.last_col,
        url = reference.url,
      })
    end
  end
end

local function schedule_refresh(bufnr, first_line, last_line)
  local range = pending[bufnr]
  if range then
    range.first = math.min(range.first, first_line)
    range.last = math.max(range.last, last_line)
    return
  end

  pending[bufnr] = { first = first_line, last = last_line }
  vim.schedule(function()
    local current = pending[bufnr]
    pending[bufnr] = nil
    if current then
      refresh(bufnr, current.first, current.last)
    end
  end)
end

function M.attach(bufnr, cwd)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  vim.b[bufnr].luanphan_terminal_reference_cwd = vim.fs.normalize(cwd)
  refresh(bufnr, 0, vim.api.nvim_buf_line_count(bufnr))

  if attached[bufnr] then
    return namespace
  end
  attached[bufnr] = true
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, changed_bufnr, _, first_line, _, last_line)
      schedule_refresh(changed_bufnr, first_line, last_line)
    end,
    on_detach = function(_, detached_bufnr)
      attached[detached_bufnr] = nil
      pending[detached_bufnr] = nil
    end,
  })
  return namespace
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
