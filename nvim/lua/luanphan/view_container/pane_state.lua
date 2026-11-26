local M = {}
local uv = vim.uv
local pane_order = require("luanphan.view_container.pane_order")
local pending, timer = {}, nil

local function read(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then return end
  local decoded, record = pcall(vim.json.decode, table.concat(lines, "\n"))
  if decoded and type(record) == "table" then return record end
end

-- Other editor instances may replace or edit these files. Stat before reusing a decode.
local directories = {}

function M.list(dir, accept_id)
  if vim.fn.isdirectory(dir) ~= 1 then
    directories[dir] = nil
    return {}
  end
  local previous, current, records = directories[dir] or {}, {}, {}
  for name, kind in vim.fs.dir(dir) do
    local id = name:match("^(.*)%.json$")
    if kind == "file" and id and accept_id(id) then
      local path = dir .. "/" .. name
      local stat = uv.fs_stat(path)
      if stat then
        local entry = previous[id]
        if not entry or entry.ino ~= stat.ino or entry.size ~= stat.size
          or entry.sec ~= stat.ctime.sec or entry.nsec ~= stat.ctime.nsec then
          entry = { ino = stat.ino, size = stat.size, sec = stat.ctime.sec, nsec = stat.ctime.nsec, record = read(path) }
        end
        if entry.record then
          current[id] = entry
          local record = vim.deepcopy(entry.record)
          if pending[path] then record.pane_order = pending[path].pane_order end
          records[id] = record
        end
      end
    end
  end
  directories[dir] = current
  return records
end

local function write(path, record, delayed)
  local previous = read(path)
  if vim.deep_equal(previous, record)
    or (delayed and previous and type(previous.last_used) == "number"
      and type(record.last_used) == "number" and previous.last_used > record.last_used) then
    return
  end
  if not pcall(vim.fn.mkdir, vim.fs.dirname(path), "p", 448) then return end
  local tmp = path .. "." .. vim.fn.getpid() .. ".tmp"
  local wrote, result = pcall(vim.fn.writefile, { vim.json.encode(record) }, tmp, "s")
  if wrote and result == 0 then uv.fs_rename(tmp, path) end
  uv.fs_unlink(tmp)
end

local function capture(item, snapshot, position)
  local path, record = snapshot(item)
  if path then record.pane_order = position or pane_order.get(item) end
  return path, record
end

function M.save(item, snapshot)
  local path, record = capture(item, snapshot)
  if not path then return end
  pending[path] = nil
  write(path, record)
end

function M.forget(path)
  pending[path] = nil
  uv.fs_unlink(path)
end

local function flush()
  if timer then vim.fn.timer_stop(timer) end
  timer = nil
  local writes = pending
  pending = {}
  for path, record in pairs(writes) do write(path, record, true) end
end

function M.defer(item, snapshot, position)
  local path, record = capture(item, snapshot, position)
  if not path then return end
  pending[path] = record
  if timer then vim.fn.timer_stop(timer) end
  timer = vim.fn.timer_start(250, flush)
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("LuanphanViewPaneState", { clear = true }),
  callback = flush,
})

return M
