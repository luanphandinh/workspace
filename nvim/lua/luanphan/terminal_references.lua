local M = {}

local namespace = vim.api.nvim_create_namespace("LuanphanTerminalReferences")
local max_wrapped_lines = 32
local path_pattern = "[@~%w%._%-%+/]+"
local position_pattern = "^(:[Ll]?(%d+):?(%d*))"
local mapped = false

local function enabled()
  return vim.g.luanphan_terminal_reference_links_enabled ~= false
    and vim.g.luanphan_terminal_reference_links_enabled ~= 0
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

local function is_web_url(value)
  return type(value) == "string" and (value:match("^http://") or value:match("^https://"))
end

local trailing_url_punctuation = {
  ["."] = true,
  [","] = true,
  [";"] = true,
  [":"] = true,
  ["!"] = true,
  ["]"] = true,
  ["}"] = true,
}

local function trim_url(value)
  local last = #value
  while last > 0 do
    local character = value:sub(last, last)
    if trailing_url_punctuation[character] then
      last = last - 1
    elseif character == ")" then
      local candidate = value:sub(1, last)
      local _, opening_count = candidate:gsub("%(", "")
      local _, closing_count = candidate:gsub("%)", "")
      if closing_count > opening_count then
        last = last - 1
      else
        break
      end
    else
      break
    end
  end
  return value:sub(1, last)
end

local function urls_in_line(text)
  local result = {}
  local offset = 1
  while offset <= #text do
    local http_first, http_last = text:find("http://[^%s%z<>\"']+", offset)
    local https_first, https_last = text:find("https://[^%s%z<>\"']+", offset)
    local first, last = http_first, http_last
    if https_first and (not first or https_first < first) then
      first, last = https_first, https_last
    end
    if not first then
      break
    end

    local scan_end = last
    local raw_url = text:sub(first, scan_end)
    local url = trim_url(raw_url)
    last = first + #url - 1

    if last >= first then
      result[#result + 1] = {
        first_col = first - 1,
        last_col = last,
        raw_last_col = scan_end,
        raw_url = raw_url,
        url = url,
      }
    end
    offset = scan_end + 1
  end
  return result
end

local function leading_url_fragment(text)
  local first, last = text:find("[^%s%z<>\"']+")
  if not first or text:sub(1, first - 1):find("%S") then
    return nil
  end
  return {
    first_col = first - 1,
    last_col = last,
    raw_last_col = last,
    value = text:sub(first, last),
  }
end

local function wrapped_url_at(line_at, row, column, text_width)
  for start_row = row, math.max(0, row - max_wrapped_lines + 1), -1 do
    local start_text = line_at(start_row) or ""
    local meaningful_end = #(start_text:gsub("%s+$", ""))
    for _, reference in ipairs(urls_in_line(start_text)) do
      if reference.raw_last_col == meaningful_end then
        local segments = {
          {
            row = start_row,
            first_col = reference.first_col,
            last_col = reference.raw_last_col,
          },
        }
        local parts = { reference.raw_url }
        local next_row = start_row + 1
        local previous_text = start_text

        while next_row < start_row + max_wrapped_lines do
          local next_text = line_at(next_row)
          if not next_text then
            break
          end
          local fragment = leading_url_fragment(next_text)
          if not fragment then
            break
          end
          local fills_row = vim.fn.strdisplaywidth(previous_text) >= text_width
          if not fills_row and fragment.first_col == 0 then
            break
          end

          local next_meaningful_end = #(next_text:gsub("%s+$", ""))
          local has_trailing_text = fragment.raw_last_col < next_meaningful_end
          local joined = table.concat(parts) .. fragment.value
          local ends_url = trim_url(joined) ~= joined
          if has_trailing_text and not fills_row and not ends_url then
            break
          end

          segments[#segments + 1] = {
            row = next_row,
            first_col = fragment.first_col,
            last_col = fragment.last_col,
          }
          parts[#parts + 1] = fragment.value

          if ends_url or has_trailing_text then
            break
          end
          previous_text = next_text
          next_row = next_row + 1
        end

        if #segments > 1 then
          local joined = table.concat(parts)
          local url = trim_url(joined)
          local removed = #joined - #url
          local last_segment = segments[#segments]
          last_segment.last_col = math.max(last_segment.first_col, last_segment.last_col - removed)

          for _, segment in ipairs(segments) do
            if segment.row == row and column >= segment.first_col and column < segment.last_col then
              return url
            end
          end
        end
      end
    end
  end
  return nil
end

local function references_in_line(cwd, text)
  local result = {}
  local offset = 1
  while offset <= #text do
    local first, last = text:find(path_pattern, offset)
    if not first then
      break
    end

    local raw_path = text:sub(first, last)
    local suffix, line, column = text:sub(last + 1):match(position_pattern)
    local path = resolve_path(cwd, raw_path)
    local line_number = tonumber(line) or 1
    local column_number = tonumber(column) or 1
    if suffix then
      last = last + #suffix
    end
    if path then
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

local function wrapped_path_at(cwd, line_at, row, column, text_width)
  for start_row = row, math.max(0, row - max_wrapped_lines + 1), -1 do
    local first_text = line_at(start_row)
    local first_col, _, value = first_text:find("(" .. path_pattern .. ")%s*$")
    if value then
      local clicked = start_row == row and column >= first_col - 1 and column < first_col + #value - 1
      local parenthesized = first_col > 1 and first_text:sub(first_col - 1, first_col - 1) == "("
      local previous_text = first_text
      for next_row = start_row + 1, start_row + max_wrapped_lines - 1 do
        local text = line_at(next_row)
        if not text then break end
        local _, last, first, fragment = text:find("^%s*()(" .. path_pattern .. ")")
        if not fragment then break end
        if first == 1 and not parenthesized and value:sub(-1) ~= "/"
            and vim.fn.strdisplaywidth(previous_text) < text_width then
          break
        end

        local suffix, line, col = text:sub(last + 1):match(position_pattern)
        if suffix then last = last + #suffix end
        clicked = clicked or (row == next_row and column >= first - 1 and column < last)
        value = value .. fragment
        if clicked then
          local path = resolve_path(cwd, value)
          if path then return { path = path, line = tonumber(line) or 1, column = tonumber(col) or 1 } end
        end
        if suffix or text:sub(last + 1):find("%S") then break end
        previous_text = text
      end
    end
  end
end

local function target_at(bufnr, row, column, text_width)
  if not enabled() or row < 0 or column < 0 then
    return nil
  end

  local cwd = vim.b[bufnr].luanphan_terminal_reference_cwd
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
  local wrapped_url = wrapped_url_at(line_at, row, column, text_width)
  if wrapped_url then
    return { url = wrapped_url }
  end
  for _, reference in ipairs(urls_in_line(current)) do
    if contains(reference) then
      return { url = reference.url }
    end
  end
  for _, reference in ipairs(references_in_line(cwd, current)) do
    if contains(reference) then
      return target(reference)
    end
  end

  return wrapped_path_at(cwd, line_at, row, column, text_width)
end

local function handle_mouse_click(key)
  local mouse = vim.fn.getmousepos()
  if not enabled() or not mouse or not mouse.winid or not vim.api.nvim_win_is_valid(mouse.winid) then
    return key
  end
  local bufnr = vim.api.nvim_win_get_buf(mouse.winid)
  if not vim.b[bufnr].luanphan_terminal_reference_cwd then return key end

  local window_info = vim.fn.getwininfo(mouse.winid)[1]
  local text_width = vim.api.nvim_win_get_width(mouse.winid) - (window_info and window_info.textoff or 0)
  local row, column = mouse.line or 0, mouse.column or 0
  local target = target_at(bufnr, row - 1, column - 1, math.max(1, text_width))
  local current_win = vim.api.nvim_get_current_win()
  local function open(target)
    if vim.api.nvim_get_current_win() == current_win
      and vim.api.nvim_win_is_valid(mouse.winid) and vim.api.nvim_win_get_buf(mouse.winid) == bufnr then
      vim.api.nvim_set_current_win(mouse.winid)
      if target.url then
        M.open_url(target.url)
      else
        M.open(target.path, target.line, target.column)
      end
    end
  end

  if target then
    vim.schedule(function() open(target) end)
    return "<Ignore>"
  end
  local pane = require("luanphan.view_container.tmux.pane")
  if pane.resolve_hyperlink(bufnr, row, column, function(url)
    if enabled() and is_web_url(url) and not url:find("[%c%s]") then open({ url = url }) end
  end) then
    return "<Ignore>"
  end
  return key
end

local function set_click_keymaps()
  local opts = {
    expr = true,
    silent = true,
    desc = "Open terminal reference",
  }
  for _, mode in ipairs({ "n", "t" }) do
    for _, key in ipairs({ "<M-LeftMouse>", "<D-LeftMouse>" }) do
      vim.keymap.set(mode, key, function()
        return handle_mouse_click(key)
      end, opts)
    end
  end
end

function M.attach(bufnr, cwd)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  vim.b[bufnr].luanphan_terminal_reference_cwd = vim.fs.normalize(cwd)
  if not mapped then
    set_click_keymaps()
    mapped = true
  end
  return namespace
end

function M.set_enabled(value, silent)
  local enabled = value == true
  vim.g.luanphan_terminal_reference_links_enabled = enabled

  if not silent then
    vim.notify("Terminal reference links " .. (enabled and "enabled" or "disabled"))
  end
  return enabled
end

function M.toggle()
  return M.set_enabled(not enabled())
end

function M.open_url(url)
  if not is_web_url(url) then
    return false
  end
  local remote = require("luanphan.remote_tunnel")
  if remote.enabled() then
    return remote.open_url(url)
  end

  local ok, _, error_message = pcall(vim.ui.open, url)
  if not ok or error_message then
    vim.notify(error_message or "Could not open URL", vim.log.levels.ERROR)
    return false
  end
  return true
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
  local close_float = source_config.relative ~= ""
    and vim.bo[source_buf].buftype == "terminal"
    and vim.b[source_buf].luanphan_persist_term
    and not vim.b[source_buf].luanphan_toggleterm
  local opened = require("luanphan.view_container.editor").open_reference(source, path, line, column)
  if opened ~= nil then return opened end
  local editor_window = require("luanphan.editor_window")
  local views = require("luanphan.view_container.window")
  local target = editor_window.find(source)

  if not target and close_float then
    views.close_group(views.group_anchor(source))
    source = nil
    target = editor_window.find()
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

  if close_float and source and vim.api.nvim_win_is_valid(source) then
    views.close_group(views.group_anchor(source))
  end
  return true
end

return M
