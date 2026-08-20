local M = {}

local MAX_ENTRIES = 256

local function state_path()
  return vim.g.luanphan_recent_paths_file
    or (vim.fn.stdpath("state") .. "/workspace-recent-paths.json")
end

local function normalize(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  local expanded = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  local normalized = (vim.uv or vim.loop).fs_realpath(expanded) or expanded
  if normalized ~= "/" then
    normalized = normalized:gsub("/+$", "")
  end
  return normalized
end

local function read_entries()
  local path = state_path()
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end

  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(decoded) ~= "table" then
    return {}
  end

  local entries = {}
  local seen = {}
  for _, value in ipairs(decoded) do
    local key = normalize(value)
    if key and not seen[key] then
      seen[key] = true
      entries[#entries + 1] = key
    end
  end
  return entries
end

local function write_entries(entries)
  local path = state_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local tmp = path .. "." .. vim.fn.getpid()
  if vim.fn.writefile({ vim.json.encode(entries) }, tmp) ~= 0 then
    return false
  end

  local ok = (vim.uv or vim.loop).fs_rename(tmp, path)
  if not ok then
    pcall(vim.fn.delete, tmp)
    return false
  end
  return true
end

function M.touch(path)
  local key = normalize(path)
  if not key then
    return false
  end

  local updated = { key }
  for _, value in ipairs(read_entries()) do
    if value ~= key and #updated < MAX_ENTRIES then
      updated[#updated + 1] = value
    end
  end
  return write_entries(updated)
end

function M.sort(items, path_of, fallback)
  local positions = {}
  for index, path in ipairs(read_entries()) do
    positions[path] = index
  end

  local decorated = {}
  for index, item in ipairs(items) do
    local key = normalize(path_of(item))
    decorated[index] = {
      item = item,
      original = index,
      position = key and positions[key] or math.huge,
    }
  end

  table.sort(decorated, function(a, b)
    if a.position ~= b.position then
      return a.position < b.position
    end
    if fallback then
      if fallback(a.item, b.item) then
        return true
      end
      if fallback(b.item, a.item) then
        return false
      end
    end
    return a.original < b.original
  end)

  for index, entry in ipairs(decorated) do
    items[index] = entry.item
  end
  return items
end

function M.switch_targets(items, path_of, current_path, fallback)
  local current = normalize(current_path)
  local targets = {}
  for _, item in ipairs(items) do
    if not current or normalize(path_of(item)) ~= current then
      targets[#targets + 1] = item
    end
  end
  return M.sort(targets, path_of, fallback)
end

return M
