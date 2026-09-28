local M = {}

local callback_port = tonumber(vim.env.NEOVIDE_REMOTE_CALLBACK_PORT)

local function log(level, message)
  io.stderr:write(string.format("[%s] [%s] neovide remote bridge: %s\n", os.date("%Y-%m-%d %H:%M:%S"), level, message))
  io.stderr:flush()
end

local function valid_port(port)
  return type(port) == "number" and port >= 1 and port <= 65535 and port % 1 == 0
end

local function is_web_url(value)
  return type(value) == "string" and (value:match("^http://") or value:match("^https://"))
end

function M.set_callback_port(port)
  port = tonumber(port)
  if not valid_port(port) then
    error("remote bridge callback port must be an integer between 1 and 65535")
  end

  callback_port = port
  vim.env.NEOVIDE_REMOTE_CALLBACK_PORT = tostring(port)
  log("Success", string.format("callback port updated: %d", port))
  return true
end

local function send_url(kind, url)
  if not is_web_url(url) then
    vim.notify("Browser bridge received an invalid URL", vim.log.levels.ERROR)
    return false
  end
  if not callback_port then
    vim.notify("Browser bridge is unavailable", vim.log.levels.ERROR)
    return false
  end

  local client = vim.uv.new_tcp()
  client:connect("127.0.0.1", callback_port, function(connect_error)
    if connect_error then
      client:close()
      vim.schedule(function()
        vim.notify("Browser bridge could not reach the local client", vim.log.levels.ERROR)
      end)
      return
    end

    client:write(kind .. " " .. url .. "\n", function(write_error)
      client:close()
      if write_error then
        vim.schedule(function()
          vim.notify("Browser bridge could not send the URL", vim.log.levels.ERROR)
        end)
      end
    end)
  end)
  return true
end

function M.open_url(url)
  return send_url("open-url", url)
end

function M.setup_url_opener()
  _G.workspace_neovide_remote_open = function(url)
    return send_url("preview-url", url)
  end

  vim.cmd([[
    function! WorkspaceNeovideRemoteOpen(url) abort
      call v:lua.workspace_neovide_remote_open(a:url)
    endfunction
  ]])

  return "WorkspaceNeovideRemoteOpen"
end

function M.setup()
  _G.workspace_neovide_set_callback_port = M.set_callback_port
  vim.cmd([[
    function! WorkspaceNeovideSetCallbackPort(port) abort
      return v:lua.workspace_neovide_set_callback_port(a:port)
    endfunction
  ]])
  M.setup_url_opener()
end

function M.paste_clipboard_image()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "t"
    or vim.b[bufnr].luanphan_agent_name ~= "codex"
    or not callback_port
  then
    return false
  end

  local helper = vim.fn.expand("~/bin/neovide-paste-image")
  if vim.fn.executable(helper) ~= 1 then
    log("Error", "neovide-paste-image is not installed")
    vim.notify("neovide-paste-image is not installed", vim.log.levels.ERROR)
    return true
  end

  log("Info", "requesting clipboard image through 127.0.0.1:" .. callback_port)
  vim.notify("Reading image from local clipboard...")
  vim.system({ helper }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local message = vim.trim(result.stderr or "")
        log("Error", "clipboard image request failed with exit status " .. result.code)
        vim.notify(message ~= "" and message or "Could not paste clipboard image", vim.log.levels.ERROR)
        return
      end

      local path = vim.trim(result.stdout or "")
      if not vim.api.nvim_buf_is_valid(bufnr) then
        log("Error", "image received after the Codex terminal closed")
        vim.notify("Codex terminal is no longer available", vim.log.levels.ERROR)
        return
      end
      local job = vim.b[bufnr].terminal_job_id
      if path == "" or type(job) ~= "number" or job <= 0 then
        log("Error", "image received without an active Codex terminal")
        vim.notify("Codex terminal is no longer available", vim.log.levels.ERROR)
        return
      end

      local sent = pcall(vim.fn.chansend, job, "[Image: " .. path .. "] ")
      if not sent then
        log("Error", "could not send the image path to Codex")
        vim.notify("Could not send the image path to Codex", vim.log.levels.ERROR)
        return
      end
      log("Success", "saved clipboard image to " .. path)
      vim.notify("Clipboard image copied to the Codex prompt")
    end)
  end)
  return true
end

return M
