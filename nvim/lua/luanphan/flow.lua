local M = {}

local uv = vim.uv or vim.loop
local menu = {}
local indices = {}

local function normalize(path)
  path = vim.fs.normalize(path)
  if path ~= "/" then
    path = path:gsub("/$", "")
  end
  return path
end

function M.scope_root()
  local cwd = vim.fn.getcwd()
  return normalize(uv.fs_realpath(cwd) or cwd)
end

function M.storage_path(root)
  root = root or M.scope_root()
  root = normalize(uv.fs_realpath(root) or root)
  local directory = vim.g.luanphan_flow_data_dir or (vim.fn.stdpath("data") .. "/flow")
  local name = vim.fn.fnamemodify(root, ":t"):gsub("[^%w._-]", "_")
  return directory .. "/" .. name .. "-" .. vim.fn.sha256(root):sub(1, 12) .. ".txt"
end

local function context()
  local root = M.scope_root()
  return {
    root = root,
    storage = M.storage_path(root),
  }
end

local function ensure_storage(ctx)
  vim.fn.mkdir(vim.fn.fnamemodify(ctx.storage, ":h"), "p")
  if vim.fn.filereadable(ctx.storage) == 0 then
    vim.fn.writefile({}, ctx.storage)
  end
end

function M.parse_entry(line)
  local value = vim.trim(line or "")
  if value == "" or vim.startswith(value, "//") then
    return nil
  end

  local path, line_number, suffix = value:match("^(.-):(%d+)(.*)$")
  if not path or (suffix ~= "" and not suffix:match("^%s+")) then
    return nil
  end

  path = vim.trim(path)
  line_number = tonumber(line_number)
  if path == "" or path:sub(1, 1) == "/" or not line_number or line_number < 1 then
    return nil
  end

  return {
    path = path,
    line = line_number,
  }
end

local function resolve_entry(ctx, text, source_line)
  local entry = M.parse_entry(text)
  if not entry then
    return nil
  end

  local path = normalize(ctx.root .. "/" .. entry.path)
  if not vim.startswith(path, ctx.root .. "/") or vim.fn.filereadable(path) ~= 1 then
    return nil
  end

  entry.full_path = path
  entry.source_line = source_line
  return entry
end

local function entries(ctx)
  ensure_storage(ctx)
  local result = {}
  for source_line, text in ipairs(vim.fn.readfile(ctx.storage)) do
    local entry = resolve_entry(ctx, text, source_line)
    if entry then
      result[#result + 1] = entry
    end
  end
  return result
end

local function close_menu(save)
  local buf = menu.buf
  local win = menu.win

  if save and buf and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
    local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
      vim.cmd("silent write")
    end)
    if not ok then
      vim.notify("Could not save Flow: " .. tostring(err), vim.log.levels.ERROR)
      return false
    end
  end

  menu = {}
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  return true
end

local function jump(ctx, entry, index)
  if not entry then
    return
  end

  indices[ctx.storage] = index
  vim.cmd("edit " .. vim.fn.fnameescape(entry.full_path))
  local last_line = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { math.min(entry.line, last_line), 0 })
end

function M.add()
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    vim.notify("Flow requires a file inside the current workspace", vim.log.levels.WARN)
    return
  end

  local ctx = context()
  file = normalize(uv.fs_realpath(file) or file)
  if not vim.startswith(file, ctx.root .. "/") then
    vim.notify("Flow cannot add a file outside the current workspace", vim.log.levels.WARN)
    return
  end

  ensure_storage(ctx)
  local relative = file:sub(#ctx.root + 2)
  vim.fn.writefile({ relative .. ":" .. vim.api.nvim_win_get_cursor(0)[1] }, ctx.storage, "a")
  indices[ctx.storage] = #entries(ctx)
end

function M.select(index)
  local ctx = context()
  jump(ctx, entries(ctx)[index], index)
end

local function current_index(ctx, items)
  local current_file = normalize(vim.api.nvim_buf_get_name(0))
  local current_line = vim.api.nvim_win_get_cursor(0)[1]
  for index, entry in ipairs(items) do
    if entry.full_path == current_file and entry.line == current_line then
      return index
    end
  end
  return indices[ctx.storage]
end

function M.next()
  local ctx = context()
  local items = entries(ctx)
  if #items == 0 then
    return
  end
  local index = (current_index(ctx, items) or 0) % #items + 1
  jump(ctx, items[index], index)
end

function M.previous()
  local ctx = context()
  local items = entries(ctx)
  if #items == 0 then
    return
  end
  local index = ((current_index(ctx, items) or 1) - 2) % #items + 1
  jump(ctx, items[index], index)
end

function M.toggle_menu()
  if menu.win and vim.api.nvim_win_is_valid(menu.win) then
    close_menu(true)
    return
  end

  local ctx = context()
  ensure_storage(ctx)

  local buf = vim.fn.bufadd(ctx.storage)
  vim.fn.bufload(buf)
  local width = math.min(math.max(48, math.floor(vim.o.columns * 0.62)), vim.o.columns - 4)
  local height = math.min(math.max(8, vim.api.nvim_buf_line_count(buf)), vim.o.lines - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "single",
    title = " Flow: " .. vim.fn.fnamemodify(ctx.root, ":t") .. " ",
    title_pos = "center",
  })

  menu = { buf = buf, win = win, context = ctx }
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "flow"
  vim.wo[win].number = true
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = false

  local function save_and_close()
    close_menu(true)
  end

  vim.keymap.set("n", "q", save_and_close, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", save_and_close, { buffer = buf, silent = true })
  vim.keymap.set("n", "<CR>", function()
    local source_line = vim.api.nvim_win_get_cursor(win)[1]
    local text = vim.api.nvim_buf_get_lines(buf, source_line - 1, source_line, false)[1]
    local entry = resolve_entry(ctx, text, source_line)
    if not close_menu(true) then
      return
    end
    if entry then
      local index = 0
      for _, item in ipairs(entries(ctx)) do
        index = index + 1
        if item.source_line == source_line then
          break
        end
      end
      jump(ctx, entry, index)
    end
  end, { buffer = buf, silent = true })
end

return M
