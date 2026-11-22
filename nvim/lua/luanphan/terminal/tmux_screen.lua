local M = {}

local function fit_text(text, cells)
  if vim.fn.strdisplaywidth(text) <= cells then return text end
  local low, high = 0, math.min(cells, vim.fn.strchars(text, true))
  while low < high do
    local middle = math.floor((low + high + 1) / 2)
    local prefix = vim.fn.strcharpart(text, 0, middle, true)
    if vim.fn.strdisplaywidth(prefix) <= cells then low = middle else high = middle - 1 end
  end
  return vim.fn.strcharpart(text, 0, low, true)
end

local function clip_row(line, left, width)
  local result, index = {}, 1
  while index <= #line do
    local start, finish = line:find("\27%[[%d;:]*m", index)
    local text = line:sub(index, start and start - 1 or #line)
    if left > 0 then
      local skipped = fit_text(text, left)
      left = left - vim.fn.strdisplaywidth(skipped)
      text = text:sub(#skipped + 1)
      if left > 0 and text ~= "" then
        local wide = vim.fn.strcharpart(text, 0, 1, true)
        text = string.rep(" ", vim.fn.strdisplaywidth(wide) - left) .. text:sub(#wide + 1)
        left = 0
      end
    end
    local fitted = fit_text(text, width)
    result[#result + 1] = fitted
    width = fitted == text and (width - vim.fn.strdisplaywidth(fitted)) or 0
    if not start then break end
    result[#result + 1] = line:sub(start, finish)
    index = finish + 1
  end
  return table.concat(result)
end

local function position(row, col)
  return ("\27[%d;%dH"):format(row + 1, col + 1)
end

local function paint_row(row, line)
  return position(row, 0) .. "\27[0m\27[2K" .. line .. "\27[0m"
end

local function append_history(output, frame, lines, first, last)
  for start = first, last, frame.height do
    local count = math.min(frame.height, last - start + 1)
    for row = 0, count - 1 do
      output[#output + 1] = paint_row(row, clip_row(lines[start + row], frame.left, frame.width))
    end
    output[#output + 1] = position(frame.height - 1, 0) .. string.rep("\r\n", count)
  end
end

local function viewport_start(cursor, size, previous)
  return math.max(0, math.min(cursor, previous or 0), cursor - size + 1)
end

function M.frame(pane, lines, flags)
  local previous = pane.frame
  local width, height = pane.view_width, pane.view_height
  local col, row = tonumber(flags[1]) or 0, tonumber(flags[2]) or 0
  local source_width, source_height = tonumber(flags[8]) or pane.width, tonumber(flags[9]) or pane.height
  local top = math.min(viewport_start(row, height, previous and previous.top), math.max(0, source_height - height))
  local left = math.min(viewport_start(col, width, previous and previous.left), math.max(0, source_width - width))
  local screen_start = math.max(0, #lines - source_height) + top
  local frame = {
    rows = {}, top = top, left = left, width = width, height = height, alternate = flags[3] == "1",
    row = math.min(row - top, height - 1), col = math.min(col - left, width - 1),
    history = tonumber(flags[7]) or 0, generation = flags[10],
    modes = { flags[4], flags[5], flags[6] },
  }
  local output = {}
  local reset = not previous or previous.alternate ~= frame.alternate
    or previous.width ~= width or previous.height ~= height
  if not previous or previous.alternate ~= frame.alternate then
    output[#output + 1] = frame.alternate and "\27[?1049h" or "\27[?1049l"
  end
  if reset then
    output[#output + 1] = "\27[r\27[0m"
  end
  if not frame.alternate then
    local scrolled = 0
    if not pane.painted then
      scrolled = screen_start
    elseif not reset and (frame.generation == previous.generation or previous.history + previous.top == 0) then
      scrolled = frame.history - previous.history + top - previous.top
    end
    if scrolled > 0 and screen_start > 0 then
      append_history(output, frame, lines, math.max(1, screen_start - scrolled + 1), screen_start)
      reset = true
    end
  end
  for index = 1, height do
    local line = clip_row(lines[screen_start + index] or "", left, width)
    frame.rows[index] = line
    if reset or line ~= previous.rows[index] then
      output[#output + 1] = paint_row(index - 1, line)
    end
  end
  for index, code in ipairs({ 25, 1, 2004 }) do
    local flag = frame.modes[index]
    if flag == "0" or flag == "1" then
      if reset or flag ~= previous.modes[index] then
        output[#output + 1] = ("\27[?%d%s"):format(code, flag == "1" and "h" or "l")
      end
    end
  end
  if #output > 0 or frame.row ~= previous.row or frame.col ~= previous.col then
    output[#output + 1] = position(frame.row, frame.col)
  end
  return frame, table.concat(output)
end

return M
