local M = {}

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

function M.paste_clipboard_image(opts)
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
    vim.notify("Reading image from the client clipboard...")
  end
  vim.system({ command, "paste-image" }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        if opts.fallback then
          opts.fallback()
          return
        end
        local message = vim.trim(result.stderr or "")
        log("Error", "clipboard image request failed with exit status " .. result.code)
        vim.notify(message ~= "" and message or "Could not paste clipboard image", vim.log.levels.ERROR)
        return
      end

      local path = vim.trim(result.stdout or "")
      if not vim.api.nvim_buf_is_valid(bufnr) then
        vim.notify("Codex terminal is no longer available", vim.log.levels.ERROR)
        return
      end
      local job = vim.b[bufnr].terminal_job_id
      if path == "" or type(job) ~= "number" or job <= 0 then
        vim.notify("Codex terminal is no longer available", vim.log.levels.ERROR)
        return
      end

      local sent = pcall(vim.fn.chansend, job, "[Image: " .. path .. "] ")
      if not sent then
        vim.notify("Could not send the image path to Codex", vim.log.levels.ERROR)
        return
      end
      log("Success", "saved clipboard image to " .. path)
      if not opts.quiet then
        vim.notify("Clipboard image copied to the Codex prompt")
      end
    end)
  end)
  return true
end

function M.setup()
  if not M.enabled() then
    return
  end

  M.setup_url_opener()
  vim.keymap.set("t", "<C-v>", function()
    if M.paste_clipboard_image() then
      return
    end
    local job = vim.b.terminal_job_id
    if type(job) == "number" and job > 0 then
      vim.fn.chansend(job, "\022")
    end
  end, { silent = true, desc = "Paste clipboard image" })
end

return M
