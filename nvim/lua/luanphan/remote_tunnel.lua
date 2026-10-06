local M = {}

local uv = vim.uv or vim.loop
local probe_interval_ms = 2000
local probe_timeout_ms = 2000
local probe_timer = nil
local cancel_probe = nil
local probe_in_flight = false
local setup_complete = false
local status_text = ""
local probe_window_size = math.floor(60000 / probe_interval_ms)
local probe_samples = {}
local probe_port = nil
local probe_token = nil

local function log(level, message)
  io.stderr:write(string.format("[%s] [%s] remote tunnel: %s\n", os.date("%Y-%m-%d %H:%M:%S"), level, message))
  io.stderr:flush()
end

local function is_web_url(value)
  return type(value) == "string" and (value:match("^http://") or value:match("^https://"))
end

local function helper()
  return vim.fn.expand("~/bin/tunnel")
end

local function connection_path()
  local cache_home = vim.env.XDG_CACHE_HOME
  if not cache_home or cache_home == "" then
    cache_home = vim.fn.expand("~/.cache")
  end
  return cache_home .. "/workspace-tunnel/connection"
end

local function read_connection()
  local file = io.open(connection_path(), "r")
  if not file then
    return nil
  end
  local line = file:read("*l") or ""
  file:close()

  local port, token = line:match("^(%d+)%s+([0-9a-f]+)%s+%S+$")
  port = tonumber(port)
  if not port or port < 1 or port > 65535 or not token or #token ~= 64 then
    return nil
  end
  return port, token
end

function M.latency_summary(samples)
  local latencies = {}
  local sum = 0
  local failures = 0
  for _, sample in ipairs(samples) do
    if type(sample) == "number" then
      latencies[#latencies + 1] = sample
      sum = sum + sample
    else
      failures = failures + 1
    end
  end

  if #latencies == 0 then
    return {
      average_ms = nil,
      deviation_ms = nil,
      p95_ms = nil,
      failures = failures,
      attempts = #samples,
    }
  end

  local average = sum / #latencies
  local squared_deviations = 0
  for _, latency in ipairs(latencies) do
    squared_deviations = squared_deviations + (latency - average) ^ 2
  end
  table.sort(latencies)

  return {
    average_ms = math.floor(average + 0.5),
    deviation_ms = math.floor(math.sqrt(squared_deviations / #latencies) + 0.5),
    p95_ms = latencies[math.ceil(#latencies * 0.95)],
    failures = failures,
    attempts = #samples,
  }
end

local function reset_probe_samples(port, token)
  probe_samples = {}
  probe_port = port
  probe_token = token
end

local function record_probe(sample)
  probe_samples[#probe_samples + 1] = sample
  if #probe_samples > probe_window_size then
    table.remove(probe_samples, 1)
  end
end

local function probe_status(connected)
  local summary = M.latency_summary(probe_samples)
  if not connected or not summary.average_ms then
    return string.format("tunnel not connected loss %d/%d", summary.failures, summary.attempts)
  end
  return string.format(
    "latency avg %d±%dms p95 %dms loss %d/%d",
    summary.average_ms,
    summary.deviation_ms,
    summary.p95_ms,
    summary.failures,
    summary.attempts
  )
end

local function set_status(value)
  if status_text == value then
    return
  end
  status_text = value
  pcall(vim.cmd, "redrawstatus")
end

local function close_handle(handle)
  if handle and not handle:is_closing() then
    handle:close()
  end
end

local function probe_latency()
  if probe_in_flight then
    return
  end

  local port, token = read_connection()
  if not port then
    reset_probe_samples(nil, nil)
    set_status("tunnel not connected")
    return
  end
  if port ~= probe_port or token ~= probe_token then
    reset_probe_samples(port, token)
  end

  probe_in_flight = true
  local started = uv.hrtime()
  local response = ""
  local socket = uv.new_tcp()
  local timeout = uv.new_timer()
  local completed = false

  local function finish(connected)
    if completed then
      return
    end
    completed = true
    probe_in_flight = false
    cancel_probe = nil
    pcall(socket.read_stop, socket)
    close_handle(socket)
    timeout:stop()
    close_handle(timeout)

    local elapsed_ms = math.floor((uv.hrtime() - started) / 1000000 + 0.5)
    vim.schedule(function()
      record_probe(connected and elapsed_ms or false)
      set_status(probe_status(connected))
    end)
  end

  cancel_probe = function()
    finish(false)
  end
  timeout:start(probe_timeout_ms, 0, function()
    finish(false)
  end)
  socket:connect("127.0.0.1", port, function(connect_error)
    if completed then
      return
    end
    if connect_error then
      finish(false)
      return
    end
    socket:read_start(function(read_error, data)
      if read_error or not data then
        finish(false)
        return
      end
      response = response .. data
      local newline = response:find("\n", 1, true)
      if newline or #response > 1024 then
        finish(response:sub(1, newline or 0) == "OK\n")
      end
    end)
    socket:write("AUTH " .. token .. " ping\n", function(write_error)
      if write_error then
        finish(false)
      end
    end)
  end)
end

local function current_codex_terminal()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "t" or vim.b[bufnr].luanphan_agent_name ~= "codex" then
    return nil
  end
  return bufnr
end

function M.enabled()
  return vim.env.WORKSPACE_REMOTE_TUNNEL ~= nil or vim.env.SSH_TTY ~= nil or vim.env.SSH_CONNECTION ~= nil
end

function M.statusline()
  return status_text
end

function M.open_url(url)
  if not is_web_url(url) then
    vim.notify("Remote tunnel received an invalid URL", vim.log.levels.ERROR)
    return false
  end
  local command = helper()
  if vim.fn.executable(command) ~= 1 then
    vim.notify("tunnel is not installed", vim.log.levels.ERROR)
    return false
  end

  vim.system({ command, "open", url }, { text = true }, function(result)
    if result.code == 0 then
      return
    end
    vim.schedule(function()
      local message = vim.trim(result.stderr or "")
      log("Error", "URL request failed with exit status " .. result.code)
      vim.notify(message ~= "" and message or "Could not open URL through the remote tunnel", vim.log.levels.ERROR)
    end)
  end)
  return true
end

function M.setup_url_opener()
  _G.workspace_remote_tunnel_open = M.open_url
  vim.cmd([[
    function! WorkspaceRemoteTunnelOpen(url) abort
      call v:lua.workspace_remote_tunnel_open(a:url)
    endfunction
  ]])
  return "WorkspaceRemoteTunnelOpen"
end

function M.clipboard_reference(output)
  output = (output or ""):gsub("\n$", ""):gsub("\r$", "")
  local separator = output:find("\t", 1, true)
  local kind = separator and output:sub(1, separator - 1) or ""
  local path = separator and output:sub(separator + 1) or ""
  if not vim.tbl_contains({ "file", "directory", "image" }, kind) or path == "" then
    return nil
  end
  local reference = kind == "image" and "[Image: " .. path .. "] " or path .. " "
  return reference, kind, path
end

function M.paste_clipboard_item(opts)
  opts = opts or {}
  local bufnr = current_codex_terminal()
  if not bufnr then
    return false
  end

  local command = helper()
  if vim.fn.executable(command) ~= 1 then
    if opts.fallback then
      opts.fallback()
    else
      vim.notify("tunnel is not installed", vim.log.levels.ERROR)
    end
    return true
  end

  if not opts.quiet then
    vim.notify("Reading from the client clipboard...")
  end
  vim.system({ command, "paste" }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        if opts.fallback then
          opts.fallback()
          return
        end
        local message = vim.trim(result.stderr or "")
        log("Error", "clipboard request failed with exit status " .. result.code)
        vim.notify(message ~= "" and message or "Could not paste the clipboard item", vim.log.levels.ERROR)
        return
      end

      local reference, kind, path = M.clipboard_reference(result.stdout)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        vim.notify("Codex terminal is no longer available", vim.log.levels.ERROR)
        return
      end
      local job = vim.b[bufnr].terminal_job_id
      if not reference then
        vim.notify("Tunnel returned an invalid clipboard item", vim.log.levels.ERROR)
        return
      end
      if type(job) ~= "number" or job <= 0 then
        vim.notify("Codex terminal is no longer available", vim.log.levels.ERROR)
        return
      end

      local sent = pcall(vim.fn.chansend, job, reference)
      if not sent then
        vim.notify("Could not send the clipboard path to Codex", vim.log.levels.ERROR)
        return
      end
      log("Success", "saved clipboard " .. kind .. " to " .. path)
      if not opts.quiet then
        vim.notify("Clipboard item copied to the Codex prompt")
      end
    end)
  end)
  return true
end

function M.setup()
  if not M.enabled() or setup_complete then
    return
  end
  setup_complete = true

  set_status("tunnel not connected")
  probe_latency()
  probe_timer = uv.new_timer()
  probe_timer:start(probe_interval_ms, probe_interval_ms, vim.schedule_wrap(probe_latency))

  local group = vim.api.nvim_create_augroup("LuanphanRemoteTunnel", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    once = true,
    callback = function()
      if cancel_probe then
        cancel_probe()
      end
      probe_timer:stop()
      close_handle(probe_timer)
      probe_timer = nil
    end,
  })

  M.setup_url_opener()
  vim.keymap.set("t", "<C-v>", function()
    if M.paste_clipboard_item() then
      return
    end
    local job = vim.b.terminal_job_id
    if type(job) == "number" and job > 0 then
      vim.fn.chansend(job, "\022")
    end
  end, { silent = true, desc = "Paste clipboard item" })
end

return M
