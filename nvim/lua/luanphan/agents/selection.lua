-- Sends the visual selection to an agent terminal as a file reference.
--
-- Send formats (config.send_mode):
--   - lines_only (default): @relative/path:<start>-<end>
--   - full: the @path:start-end header, then the selected text (truncated by max_send_chars).

local M = {}

M.defaults = {
  max_send_chars = 256 * 1024,
  send_mode = "lines_only",
}

local function exit_visual_to_normal()
  -- Consume Escape before focusing the terminal, where it would interrupt the agent.
  vim.cmd.normal({ args = { vim.keycode("<Esc>") }, bang = true })
end

local function payload(api, notify, bufnr, lines, line_start, line_end)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    notify("save the buffer to use @path:start-end", vim.log.levels.WARN)
    return nil
  end
  local header = string.format("@%s:%d-%d", vim.fn.fnamemodify(name, ":."), line_start, line_end)
  local config = api.config
  -- No trailing newline: the terminal cursor stays after @path:start-end.
  if config.send_mode == "lines_only" then return header end
  local body = table.concat(lines, "\n")
  if #body > config.max_send_chars then
    body = body:sub(1, config.max_send_chars) .. "\n... [truncated after " .. config.max_send_chars .. " chars]"
    notify("selection truncated", vim.log.levels.WARN)
  end
  return header .. "\n\n" .. body .. "\n"
end

-- Adds `send_selection(target_bufnr, opts)` to a terminal session API.
function M.attach(api, name)
  local function notify(message, level)
    vim.notify((name or "agent") .. ": " .. message, level or vim.log.levels.INFO)
  end

  function api.send_selection(target_bufnr, opts)
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.bo[bufnr].buftype ~= "" then
      notify("not supported in this buffer", vim.log.levels.WARN)
      exit_visual_to_normal()
      return
    end
    -- In Visual mode '< and '> still hold the previous selection; 'v' and '.' are the live one.
    local first, last = vim.fn.line("v"), vim.fn.line(".")
    local lines
    if api.config.send_mode == "full" then
      lines = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = vim.fn.visualmode() })
      if not lines or #lines == 0 then
        notify("empty selection")
        exit_visual_to_normal()
        return
      end
    end
    exit_visual_to_normal()
    local text = payload(api, notify, bufnr, lines, math.min(first, last), math.max(first, last))
    if text then api.paste(text, target_bufnr, opts) end
  end
  return api
end

return M
