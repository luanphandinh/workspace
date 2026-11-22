local M = {}
local Client = {}
Client.__index = Client

local function argv(args)
  local command = { "tmux" }
  local socket = vim.g.luanphan_floating_tmux_socket
  if not socket and vim.env.TMUX then
    local inherited = vim.env.TMUX:match("^(.*),%d+,%d+$")
    if inherited and vim.uv.fs_stat(inherited) then socket = inherited end
  end
  if type(socket) == "string" and socket ~= "" then vim.list_extend(command, { "-S", socket }) end
  if vim.g.luanphan_floating_tmux_config then
    vim.list_extend(command, { "-f", vim.g.luanphan_floating_tmux_config })
  end
  return vim.list_extend(command, args)
end

local function environment()
  local env = vim.fn.environ()
  env.TMUX, env.TMUX_PANE = nil, nil
  return env
end

local function run(args)
  return vim.system(argv(args), { text = true, clear_env = true, env = environment() }):wait(2000)
end

local function quote(value)
  return '"' .. tostring(value):gsub('[\\"$]', '\\%0'):gsub("\n", "\\n"):gsub("\r", "\\r") .. '"'
end

function M.sessions()
  local result = run({ "list-sessions", "-F", "#{session_id}\t#{session_attached}\t#{session_activity}\t#{session_name}" })
  local sessions = {}
  for line in (result.stdout or ""):gmatch("[^\n]+") do
    local id, attached, activity, name = line:match("^(%$%d+)\t(%d+)\t(%d+)\t(.*)$")
    if id then
      sessions[#sessions + 1] = { id = id, title = name, label = name, attached = tonumber(attached), activity = tonumber(activity) }
    end
  end
  table.sort(sessions, function(a, b)
    if a.activity ~= b.activity then return a.activity > b.activity end
    return a.id < b.id
  end)
  return sessions
end

function M.ensure_session(previous, width, height)
  local sessions = M.sessions()
  for _, session in ipairs(sessions) do
    if session.id == previous then return session end
  end
  if sessions[1] then return sessions[1] end
  local result = run({
    "new-session", "-dA", "-s", "terminal", "-c", vim.fn.getcwd(),
    "-x", tostring(width), "-y", tostring(height),
  })
  -- Another client may have created the first session after list-sessions.
  local session = M.sessions()[1]
  if session then return session end
  vim.notify(vim.trim(result.stderr or "Could not create tmux session"), vim.log.levels.ERROR)
end

function Client:flush()
  if not self.ready or self.pending or not self.job then return end
  local request = table.remove(self.queue, 1)
  if not request then return end
  self.pending = request
  vim.api.nvim_chan_send(self.job, request.command .. "\n")
end

function Client:request_batch(commands, callback)
  local lines = vim.tbl_map(function(args) return table.concat(vim.tbl_map(quote, args), " ") end, commands)
  self.queue[#self.queue + 1] = {
    command = table.concat(lines, "\n"), count = #commands, replies = {}, callback = callback,
  }
  self:flush()
end

function Client:request(args, callback)
  self:request_batch({ args }, callback and function(replies) callback(replies[1].ok, replies[1].lines) end)
end

local function decode(bytes)
  return (bytes:gsub("\\([0-7][0-7][0-7])", function(octal) return string.char(tonumber(octal, 8)) end))
end

function Client:line(line)
  local id = line:match("^%%begin (%d+ %d+ %d+)$")
  if self.block then
    local ending = line:match("^%%end (%d+ %d+ %d+)$")
    local failure = line:match("^%%error (%d+ %d+ %d+)$")
    if ending == self.block or failure == self.block then
      local lines = self.lines
      local request = tonumber(self.block:match("%d+$")) % 2 == 1 and self.pending
      self.block, self.lines = nil, nil
      if request then
        request.replies[#request.replies + 1] = { ok = ending ~= nil, lines = lines }
        if #request.replies == request.count then
          self.pending = nil
          if request.callback then request.callback(request.replies) end
        end
      end
      self:flush()
    else
      self.lines[#self.lines + 1] = line
    end
  elseif id then
    self.block, self.lines = id, {}
  else
    local pane, bytes = line:match("^%%output (%%%d+) (.*)$")
    if not pane then pane, bytes = line:match("^%%extended%-output (%%%d+) .- : (.*)$") end
    if pane then
      self.handlers.output(pane, decode(bytes))
      return
    end
    local event, payload = line:match("^%%([%w%-]+) *(.*)$")
    if event == "session-changed" and not self.ready then
      self.ready = true
      self.handlers.ready()
      self:flush()
    elseif event then
      self.handlers.event(event, payload)
    end
  end
end

function Client:detach()
  local job = self.job
  self.job, self.queue, self.ready = nil, {}, false
  if job then
    pcall(vim.api.nvim_chan_send, job, "\n")
    local closed = pcall(vim.fn.chanclose, job, "stdin")
    if not closed then pcall(vim.fn.jobstop, job) end
  end
end

function M.attach(session, handlers)
  local client = setmetatable({ queue = {}, handlers = handlers }, Client)
  local flags = session.attached > 0 and "ignore-size,pause-after=5" or "pause-after=5"
  local fragment = ""
  local job = vim.fn.jobstart(argv({ "-C", "attach-session", "-f", flags, "-t", session.id }), {
    clear_env = true,
    env = environment(),
    on_stdout = function(_, data)
      if not client.job or #data == 0 then return end
      data[1] = fragment .. data[1]
      fragment = table.remove(data)
      for _, line in ipairs(data) do
        if not client.job then return end
        client:line(line)
      end
    end,
    on_stderr = function(_, data)
      local message = vim.trim(table.concat(data, "\n"))
      if message ~= "" then client.error = message end
    end,
    on_exit = function(_, code)
      local attached = client.job
      client.job = nil
      if attached then handlers.exit(code, client.error) end
    end,
  })
  if job <= 0 then
    vim.notify("Could not attach to tmux", vim.log.levels.ERROR)
    return
  end
  client.job = job
  return client
end

return M
