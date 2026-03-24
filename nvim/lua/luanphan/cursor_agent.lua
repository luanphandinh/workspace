-- Cursor CLI agent inside Neovim (no extra plugins).
-- Prerequisite: install Cursor CLI and ensure `agent` is on your PATH (verify with `which agent` in a shell).
--   Install: https://cursor.com/docs/cli/overview — default command is `agent`; override via setup({ cmd = "/full/path/to/agent" }).
--
-- Send format for selections:
--   - lines_only (default): @relative/path:<start>-<end> e.g. @nvim/init.lua:22-36
--   - full: same @path:start-end header, then full selected text (truncated by max_send_chars).

local M = {}

local state = {
  bufnr = nil,
}

local DEFAULTS = {
  cmd = "agent",
  args = {},
  split = "vertical", -- "vertical" | "horizontal"
  width = nil, -- optional: columns (vertical) or use ratio
  height = nil, -- optional: rows (horizontal)
  split_ratio = 0.38,
  max_send_chars = 256 * 1024,
  defer_send_ms = 200,
  --- "lines_only": @path:start-end only. "full": @path:start-end + selected text.
  send_mode = "lines_only",
}

local config = vim.deepcopy(DEFAULTS)

local function merge(dst, src)
  for k, v in pairs(src) do
    dst[k] = v
  end
  return dst
end

local function argv_for_termopen()
  local cmd = config.cmd
  local args = config.args or {}
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
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
  return nil
end

--- Vertical split with new window on the right (does not change global 'splitright' afterward).
local function vsplit_right()
  local saved = vim.o.splitright
  vim.o.splitright = true
  vim.cmd("vsplit")
  vim.o.splitright = saved
end

local function apply_split_size()
  if config.split == "vertical" then
    if config.width then
      vim.cmd("vertical resize " .. tonumber(config.width))
    elseif config.split_ratio then
      local total = vim.o.columns
      local w = math.floor(total * config.split_ratio)
      w = math.max(20, math.min(w, total - 10))
      vim.cmd("vertical resize " .. w)
    end
  else
    if config.height then
      vim.cmd("resize " .. tonumber(config.height))
    elseif config.split_ratio then
      local total = vim.o.lines - vim.o.cmdheight - 1
      local h = math.floor(total * config.split_ratio)
      h = math.max(8, math.min(h, total - 2))
      vim.cmd("resize " .. h)
    end
  end
end

local function valid_job_id(job)
  return type(job) == "number" and job > 0
end

local function term_buffer_alive(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if vim.bo[bufnr].buftype ~= "terminal" then
    return false
  end
  local ok, job = pcall(vim.fn.getbufvar, bufnr, "terminal_job_id")
  return ok and valid_job_id(job)
end

local function open_terminal()
  if config.split == "vertical" then
    vsplit_right()
  else
    vim.cmd("split")
  end
  vim.cmd("enew")
  apply_split_size()
  local buf = vim.api.nvim_get_current_buf()
  local cwd = vim.fn.getcwd()
  vim.fn.termopen(argv_for_termopen(), { cwd = cwd })
  state.bufnr = buf
  vim.defer_fn(function()
    vim.cmd("startinsert")
  end, 10)

  vim.api.nvim_create_autocmd("TermClose", {
    buffer = buf,
    once = true,
    callback = function()
      if state.bufnr == buf then
        state.bufnr = nil
      end
    end,
  })
end

local function show_terminal()
  if config.split == "vertical" then
    vsplit_right()
  else
    vim.cmd("split")
  end
  vim.api.nvim_win_set_buf(0, state.bufnr)
  apply_split_size()
  vim.defer_fn(function()
    vim.cmd("startinsert")
  end, 10)
end

function M.toggle()
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) and term_buffer_alive(state.bufnr) then
    local win = win_for_buf(state.bufnr)
    if win then
      vim.api.nvim_win_close(win, false)
      return
    end
    show_terminal()
    return
  end
  state.bufnr = nil
  open_terminal()
end

local function get_job_id(bufnr)
  local ok, job = pcall(vim.fn.getbufvar, bufnr, "terminal_job_id")
  if not ok or not valid_job_id(job) then
    return nil
  end
  return job
end

local function format_selection_payload(bufnr, lines, line_start, line_end)
  local path = buf_shortpath(bufnr)
  if path == "[No Name]" then
    vim.notify("cursor_agent: save the buffer to use @path:start-end", vim.log.levels.WARN)
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
    vim.notify("cursor_agent: selection truncated", vim.log.levels.WARN)
  end
  return header .. "\n\n" .. body .. "\n"
end

local function exit_visual_to_normal()
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
end

function M.send_selection()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].buftype ~= "" then
    vim.notify("cursor_agent: not supported in this buffer", vim.log.levels.WARN)
    exit_visual_to_normal()
    return
  end

  local line_start = vim.fn.line("'<")
  local line_end = vim.fn.line("'>")

  local lines = nil
  if config.send_mode == "full" then
    local vmode = vim.fn.visualmode()
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    lines = vim.fn.getregion(start_pos, end_pos, { type = vmode })
    if not lines or #lines == 0 then
      vim.notify("cursor_agent: empty selection", vim.log.levels.INFO)
      exit_visual_to_normal()
      return
    end
  end

  exit_visual_to_normal()

  local payload = format_selection_payload(bufnr, lines, line_start, line_end)
  if not payload then
    return
  end

  local function focus_term_win()
    local w = win_for_buf(state.bufnr)
    if w then
      vim.api.nvim_set_current_win(w)
      vim.cmd("startinsert")
    end
  end

  local function deliver(attempt)
    attempt = attempt or 1
    if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) or not term_buffer_alive(state.bufnr) then
      if attempt < 3 then
        vim.defer_fn(function()
          deliver(attempt + 1)
        end, config.defer_send_ms)
        return
      end
      vim.notify("cursor_agent: terminal not ready", vim.log.levels.ERROR)
      return
    end

    local win = win_for_buf(state.bufnr)
    if not win then
      show_terminal()
    end

    local job = get_job_id(state.bufnr)
    if not job and attempt < 3 then
      vim.defer_fn(function()
        deliver(attempt + 1)
      end, config.defer_send_ms)
      return
    end
    if not job then
      vim.notify("cursor_agent: no terminal job", vim.log.levels.ERROR)
      return
    end

    local ok, err = pcall(vim.fn.chansend, job, payload)
    if not ok then
      vim.notify("cursor_agent: send failed: " .. tostring(err), vim.log.levels.ERROR)
      state.bufnr = nil
      return
    end

    focus_term_win()
  end

  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) or not term_buffer_alive(state.bufnr) then
    state.bufnr = nil
    open_terminal()
    vim.defer_fn(function()
      deliver(1)
    end, config.defer_send_ms)
    return
  end

  deliver(1)
end

function M.setup(opts)
  config = merge(vim.deepcopy(DEFAULTS), opts or {})

  vim.keymap.set("n", "<leader>cc", function()
    M.toggle()
  end, { desc = "Toggle Cursor agent terminal" })

  vim.keymap.set("x", "<leader>ca", function()
    M.send_selection()
  end, { desc = "Send selection to Cursor agent" })
end

return M
