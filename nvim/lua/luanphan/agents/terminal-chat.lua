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
local terminal_window = require("luanphan.terminal.window")
local backend = require("luanphan.agents.tmux")
M.running, M.close_window = terminal_window.running, view_container.close_window

local BASE_DEFAULTS = {
  cmd = "agent",
  args = {},
  float_border = "single",
  float_zindex = 45,
  scrollback = nil,
  max_send_chars = 256 * 1024,
  defer_send_ms = 200,
  send_mode = "lines_only",
}

local TERMINAL_WINHIGHLIGHT = "NormalFloat:Normal,EndOfBuffer:,WinBar:Normal,WinBarNC:Normal,"
  .. "TabLineSel:Title,TabLine:LineNr,TabLineFill:Normal"

---@param profile table
---@field name? string stable provider name
---@field shell? boolean forward Ctrl+L to an interactive shell
---@field status? table provider status options
---@field new_session_id? fun(): string
---@field hint_open string hint when no terminal (e.g. "<leader>a")
---@field defaults? table merged into BASE_DEFAULTS (cmd, args, …)
---@field on_prepare? fun(win: integer)
---@field on_show? fun(bufnr: integer, win: integer, cwd: string)
---@field on_close? fun(bufnr: integer, cwd: string)
---@field on_quit? fun(bufnr: integer, cwd: string): function?
---@field on_navigate? fun(win: integer, direction: string)
---@field on_float_layout? fun(win: integer, layout: table, opening?: boolean)
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

  local DEFAULTS = vim.tbl_deep_extend("force", vim.deepcopy(BASE_DEFAULTS), profile.defaults or {})

  local config = vim.deepcopy(DEFAULTS)

  local function cwd_key()
    return vim.fn.getcwd()
  end

  local function current_bufnr(cwd)
    local selected
    local selected_sequence = -1
    for _, pane in ipairs(backend.panes(provider_name, cwd or cwd_key())) do
      local buf = pane.bufnr
      if vim.fn.bufwinid(buf) ~= -1 then return buf end
      local sequence = tonumber(vim.b[buf].luanphan_agent_last_used) or 0
      if sequence > selected_sequence then
        selected, selected_sequence = buf, sequence
      end
    end
    return selected
  end

  local function command_for_agent(opts)
    local cmd = config.cmd
    if type(cmd) == "function" then cmd = cmd() end
    local args = (opts and opts.args) or config.args or {}
    if type(cmd) == "table" then
      local out = vim.deepcopy(cmd)
      vim.list_extend(out, args)
      return out
    end
    local out = { cmd }
    vim.list_extend(out, args)
    return out
  end

  local function buf_shortpath(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then
      return "[No Name]"
    end
    return vim.fn.fnamemodify(name, ":.")
  end

  local function win_for_buf(bufnr)
    return vim.fn.win_findbuf(bufnr)[1]
  end

  local function mark_terminal_used(bufnr)
    local sequence = (tonumber(vim.g.luanphan_agent_use_sequence) or 0) + 1
    vim.g.luanphan_agent_use_sequence = sequence
    vim.b[bufnr].luanphan_agent_last_used = sequence
  end

  local API = terminal_session.create(vim.tbl_extend("force", profile, {
    backend = backend,
    config = config,
    notify = nx,
    augroup = augroup_name,
    current = current_bufnr,
    panes = function() return backend.panes(provider_name) end,
    cwd = function(buf) return vim.b[buf].luanphan_agent_cwd end,
    mark_used = mark_terminal_used,
    settings = profile.on_float_layout and function() return require("luanphan.global_settings").read().agent_float end,
    highlights = TERMINAL_WINHIGHLIGHT,
    command = function(buf, cwd, opts)
      local thread_id = opts and opts.thread_id
      if not thread_id and profile.new_session_id then thread_id = profile.new_session_id() end
      local label = opts and opts.agent_label
      vim.b[buf].luanphan_agent_thread_id = thread_id
      vim.b[buf].luanphan_agent_saved_label = label
      return command_for_agent(opts), {
        cwd = cwd,
        workspace = require("luanphan.plugins.worktree").agent_workspace(cwd),
        agent = provider_name,
        thread_id = thread_id,
        label = label or provider_name,
      }
    end,
    on_register = function(buf)
      if status_options.initial and not vim.b[buf].luanphan_agent_program_status then
        require("luanphan.agents.status").update(buf, status_options.initial)
      end
    end,
    on_adopt = function(buf, data)
      vim.b[buf].luanphan_agent_thread_id = data.thread_id
      vim.b[buf].luanphan_agent_saved_label = data.label
      vim.b[buf].luanphan_agent_program_status = data.status
      vim.b[buf].luanphan_agent_last_used = data.used
      vim.b[buf].luanphan_agent_saved_use = data.used_at
    end,
  }))

  local setup_panel = API.setup
  function API.setup(opts)
    for key in pairs(config) do config[key] = nil end
    for key, value in pairs(vim.tbl_extend("force", vim.deepcopy(DEFAULTS), opts or {})) do config[key] = value end
    setup_panel()
  end

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
    if not payload then
      return
    end

    local function target_terminal()
      if target_bufnr and M.running(target_bufnr) then
        return target_bufnr
      end
      return current_bufnr()
    end

    local function focus_term_win()
      local cur = target_terminal()
      if not cur then return end
      local w = win_for_buf(cur)
      if w then
        vim.api.nvim_set_current_win(w)
        vim.cmd("startinsert")
      end
    end

    local function deliver(attempt)
      attempt = attempt or 1
      local cur = target_terminal()
      if not cur or not M.running(cur) then
        if attempt < 3 then
          vim.defer_fn(function()
            deliver(attempt + 1)
          end, config.defer_send_ms)
          return
        end
        nx("terminal not ready", vim.log.levels.ERROR)
        return
      end

      local win = win_for_buf(cur)
      if not win then
        API.focus(cur, opts)
      end

      if not terminal_window.send(cur, "\27[200~" .. payload .. "\27[201~") then
        nx("could not send to the terminal", vim.log.levels.ERROR)
        return
      end

      focus_term_win()
    end

    local cur = target_terminal()
    if not cur or not M.running(cur) then
      API.new(opts)
      vim.defer_fn(function()
        deliver(1)
      end, config.defer_send_ms)
      return
    end

    deliver(1)
  end

  return API
end

return M
