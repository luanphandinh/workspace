local M = {}

local function log(level, message)
  io.stderr:write(string.format("[%s] [%s] neovide remote bridge: %s\n", os.date("%Y-%m-%d %H:%M:%S"), level, message))
  io.stderr:flush()
end

function M.setup_url_opener(remote_open_port)
  _G.workspace_neovide_remote_open = function(url)
    if type(url) ~= "string" or not url:match("^https?://") then
      vim.notify("Markdown preview returned an invalid URL", vim.log.levels.ERROR)
      return
    end

    local client = vim.uv.new_tcp()
    client:connect("127.0.0.1", remote_open_port, function(connect_error)
      if connect_error then
        client:close()
        vim.schedule(function()
          vim.notify("Markdown preview could not reach the local browser bridge", vim.log.levels.ERROR)
        end)
        return
      end

      client:write(url .. "\n", function(write_error)
        client:close()
        if write_error then
          vim.schedule(function()
            vim.notify("Markdown preview could not send the URL to the local browser", vim.log.levels.ERROR)
          end)
        end
      end)
    end)
  end

  vim.cmd([[
    function! WorkspaceNeovideRemoteOpen(url) abort
      call v:lua.workspace_neovide_remote_open(a:url)
    endfunction
  ]])

  return "WorkspaceNeovideRemoteOpen"
end

function M.paste_clipboard_image()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "t"
    or vim.b[bufnr].luanphan_agent_name ~= "codex"
    or not vim.env.NEOVIDE_REMOTE_IMAGE_PORT
  then
    return false
  end

  local helper = vim.fn.expand("~/bin/neovide-paste-image")
  if vim.fn.executable(helper) ~= 1 then
    log("Error", "neovide-paste-image is not installed")
    vim.notify("neovide-paste-image is not installed", vim.log.levels.ERROR)
    return true
  end

  log("Info", "requesting clipboard image through 127.0.0.1:" .. vim.env.NEOVIDE_REMOTE_IMAGE_PORT)
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
