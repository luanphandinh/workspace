local M = {
  icon = "\u{ec81}",
  icon_color = "#FFFFFF",
  plugin = "luanphan-codex-agent",
  status = { initial = "idle" },
}
local pending = {}
local uuid_prefix = string.rep("%x", 8) .. ("%-" .. string.rep("%x", 4)):rep(3) .. "%-" .. string.rep("%x", 5)
local uuid = require("luanphan.view_container.uuid").pattern

function M.resume(id)
  local args = { "resume", "-c", 'tui.terminal_title=["session-id","thread-name"]' }
  if id then table.insert(args, 2, id) end
  return args
end

M.defaults = { cmd = "mcodex", args = M.resume() }

local function parse_title(title)
  if type(title) ~= "string" then return nil end
  local prefix, label = title:match("^(" .. uuid_prefix .. ")%.%.%.(.*)$")
  if not prefix then return nil end
  label = vim.trim(label):gsub("^|%s*", "")
  return prefix:lower(), label
end

function M.display_title(title)
  local _, label = parse_title(title)
  return label or title
end

function M.saved_title(bufnr)
  local buf = vim.b[bufnr]
  local prefix, label = parse_title(buf.term_title)
  if not prefix or vim.startswith(buf.luanphan_view_thread_id or "", prefix) then
    return label
  end
  return false
end

local function candidates(output, prefix)
  local found
  for line in output:gmatch("[^\r\n]+") do
    local id = line:match(uuid) and line or line:match("(" .. uuid:sub(2, -2) .. ")%.jsonl$")
    if id and vim.startswith(id, prefix) then
      if found and found ~= id then return nil end
      found = id
    end
  end
  return found
end

local function resolve(prefix, callback)
  local home = vim.env.CODEX_HOME or (vim.fn.expand("~") .. "/.codex")
  local function rollouts()
    if vim.fn.executable("rg") ~= 1 then return callback(nil) end
    vim.system({ "rg", "--files", "-g", "*" .. prefix .. "*.jsonl", home .. "/sessions" },
      { text = true, timeout = 2000 }, vim.schedule_wrap(function(result)
        callback(candidates(result.stdout or "", prefix))
      end))
  end
  if vim.fn.executable("sqlite3") ~= 1 then return rollouts() end
  local db_home = vim.env.CODEX_SQLITE_HOME or home
  local database
  local version = 0
  if vim.fn.isdirectory(db_home) == 1 then
    for name in vim.fs.dir(db_home) do
      local current = tonumber(name:match("^state_(%d+)%.sqlite$")) or 0
      if current > version then version, database = current, db_home .. "/" .. name end
    end
  end
  if not database then return rollouts() end
  local sql = "SELECT id FROM threads WHERE archived = 0 AND id GLOB '" .. prefix .. "*' LIMIT 2"
  vim.system({ "sqlite3", "-readonly", database, sql }, { text = true, timeout = 2000 },
    vim.schedule_wrap(function(result)
      local output = vim.trim(result.stdout or "")
      if result.code == 0 and output ~= "" then return callback(candidates(output, prefix)) end
      rollouts()
    end))
end

local function observe(bufnr, emit, attempt)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.b[bufnr].luanphan_view_kind ~= "codex" then return end
  local buf = vim.b[bufnr]
  local prefix = parse_title(buf.term_title)
  if not prefix then return end
  if vim.startswith(buf.luanphan_view_thread_id or "", prefix) then
    emit({ thread_id = buf.luanphan_view_thread_id })
    return
  end
  if pending[bufnr] == prefix then return end
  pending[bufnr] = prefix
  resolve(prefix, function(id)
    if pending[bufnr] ~= prefix then return end
    pending[bufnr] = nil
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if parse_title(buf.term_title) ~= prefix then return end
    if not id then
      if (attempt or 0) < 3 then
        vim.defer_fn(function() observe(bufnr, emit, (attempt or 0) + 1) end, 500)
      end
      return
    end
    emit({ thread_id = id })
  end)
end

function M.decode_event(bufnr, event, emit)
  if event.title or event.status == "working" or event.status == "done" then
    vim.schedule(function()
      observe(bufnr, emit)
      if event.title then emit({ refresh_title = true }) end
    end)
  end
end

return M
