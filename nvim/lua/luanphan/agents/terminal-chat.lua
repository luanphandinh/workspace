-- Shared terminal agent factory used by the lazy agent specs.
--
-- Agent terminals are scoped per-worktree: each cwd owns its agent buffers.
-- Switching worktree (|worktree.lua|) hides but does not kill these buffers.
--
-- Send format for selections:
--   - lines_only (default): @relative/path:<start>-<end>
--   - full: @path:start-end header, then full selected text (truncated by max_send_chars).

local M = {}
local view_container = require("luanphan.view_container")
local terminal_session = require("luanphan.view_container.terminal_session")
local terminal = require("luanphan.view_container.terminal")
M.running, M.close_window = terminal.running, view_container.close_window

local BASE_DEFAULTS = {
  cmd = "agent",
  args = {},
  max_send_chars = 256 * 1024,
  send_mode = "lines_only",
}

function M.create(profile)
  profile = vim.tbl_extend("force", {
    name = "terminal_agent",
    hint_open = "<leader>xx",
    defaults = {},
  }, profile)

  local provider_name = profile.name
  local augroup_name = "LuanphanAgent_" .. provider_name
  local function nx(msg, level)
    vim.notify(provider_name .. ": " .. msg, level or vim.log.levels.INFO)
  end

  local status_options = profile.status or {}

  local function buf_shortpath(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then
      return "[No Name]"
    end
    return vim.fn.fnamemodify(name, ":.")
  end

  local API = terminal_session.create(vim.tbl_extend("force", profile, {
    defaults = vim.tbl_deep_extend("force", vim.deepcopy(BASE_DEFAULTS), profile.defaults or {}),
    notify = nx,
    augroup = augroup_name,
    on_register = function(buf)
      if status_options.initial and not vim.b[buf].luanphan_view_status then
        require("luanphan.agents.status").update(buf, status_options.initial)
      end
    end,
  }))

  local config = API.config

  local function format_selection_payload(bufnr, lines, line_start, line_end)
    local path = buf_shortpath(bufnr)
    if path == "[No Name]" then
      nx("save the buffer to use @path:start-end", vim.log.levels.WARN)
      return nil
    end

    local header = string.format("@%s:%d-%d", path, line_start, line_end)
    if config.send_mode == "lines_only" then
      -- No trailing newline: terminal cursor stays on same line after @path:start-end.
      return header
    end

    local body = table.concat(lines, "\n")
    if #body > config.max_send_chars then
      body = body:sub(1, config.max_send_chars)
        .. "\n... [truncated after "
        .. config.max_send_chars
        .. " chars]"
      nx("selection truncated", vim.log.levels.WARN)
    end
    return header .. "\n\n" .. body .. "\n"
  end

  local function exit_visual_to_normal()
    -- Consume Escape before focusing the terminal, where it would interrupt the agent.
    vim.cmd.normal({ args = { vim.keycode("<Esc>") }, bang = true })
  end

  function API.send_selection(target_bufnr, opts)
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.bo[bufnr].buftype ~= "" then
      nx("not supported in this buffer", vim.log.levels.WARN)
      exit_visual_to_normal()
      return
    end

    -- While still in Visual mode, '< and '> are the *previous* selection; use 'v' (visual start) and
    -- '.' (cursor) for the active selection. See :help `v
    local l1, l2 = vim.fn.line("v"), vim.fn.line(".")
    local line_start = math.min(l1, l2)
    local line_end = math.max(l1, l2)

    local lines = nil
    if config.send_mode == "full" then
      local vmode = vim.fn.visualmode()
      local start_pos = vim.fn.getpos("v")
      local end_pos = vim.fn.getpos(".")
      lines = vim.fn.getregion(start_pos, end_pos, { type = vmode })
      if not lines or #lines == 0 then
        nx("empty selection", vim.log.levels.INFO)
        exit_visual_to_normal()
        return
      end
    end

    exit_visual_to_normal()

    local payload = format_selection_payload(bufnr, lines, line_start, line_end)
    if payload then API.paste(payload, target_bufnr, opts) end
  end

  return API
end

return M
