local M = {}
local api = vim.api
local tmux = require("luanphan.view_container.tmux.pane")
local closing_tiles = {}

local window_options = {
  breakindent = false,
  colorcolumn = "",
  concealcursor = "",
  conceallevel = 0,
  cursorbind = false,
  cursorcolumn = false,
  cursorline = false,
  diff = false,
  foldcolumn = "0",
  foldenable = false,
  foldexpr = "0",
  foldmethod = "manual",
  linebreak = false,
  list = false,
  number = false,
  relativenumber = false,
  scrollbind = false,
  scrolloff = 0,
  signcolumn = "no",
  smoothscroll = false,
  spell = false,
  statuscolumn = "",
  winblend = 0,
  winfixbuf = false,
  winfixheight = false,
  winfixwidth = false,
  wrap = false,
}

function M.configure_buffer(buf)
  pcall(vim.treesitter.stop, buf)
  pcall(api.nvim_buf_call, buf, function()
    vim.bo.syntax = ""
    vim.b.matchparen_timeout = 0
    vim.b.matchparen_insert_timeout = 0
  end)
end

function M.configure_window(win, highlights)
  if not win or not api.nvim_win_is_valid(win) then return end
  local buf = api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype == "terminal" then M.configure_buffer(buf) end
  local scope = { win = win, scope = "local" }
  for name, value in pairs(window_options) do
    pcall(api.nvim_set_option_value, name, value, scope)
  end
  api.nvim_set_option_value("winhighlight", highlights, scope)
end

function M.save_view(win, buf)
  if not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= buf or vim.bo[buf].buftype ~= "terminal" then return end
  local pane = tmux.for_buffer(buf)
  if pane then return tmux.save_view(pane, win) end
  local ok, view = pcall(api.nvim_win_call, win, vim.fn.winsaveview)
  if ok then
    vim.b[buf].luanphan_terminal_view = { follow = view.lnum >= api.nvim_buf_line_count(buf), view = view }
  end
end

function M.track_view(buf, group)
  api.nvim_create_autocmd({ "WinLeave", "BufWinLeave" }, {
    buffer = buf,
    group = group,
    callback = function() M.save_view(api.nvim_get_current_win(), buf) end,
  })
end

function M.is_scrolled(buf)
  local pane = tmux.for_buffer(buf)
  if pane then return pane.follow_live == false end
  local saved = vim.b[buf].luanphan_terminal_view
  return type(saved) == "table" and saved.follow == false
end

function M.show_view(win, buf, opened)
  if not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= buf then return end
  local pane = tmux.for_buffer(buf)
  if pane then return tmux.show_view(pane, win) end
  local job = vim.b[buf].terminal_job_id
  if type(job) ~= "number" or job <= 0 then return end
  local saved = vim.b[buf].luanphan_terminal_view
  if opened and type(saved) == "table" and saved.follow == false and type(saved.view) == "table" then
    pcall(api.nvim_win_call, win, function() vim.fn.winrestview(saved.view) end)
  end
  local width, height = tmux.grid_size(win)
  local previous = vim.b[buf].luanphan_terminal_grid
  if type(previous) == "table" and previous.width == width and previous.height == height then return end
  if pcall(vim.fn.jobresize, job, width, height) then
    vim.b[buf].luanphan_terminal_grid = { width = width, height = height }
  end
end

function M.set_reference_cwd(buf, cwd)
  if cwd and cwd ~= "" then require("luanphan.terminal_references").attach(buf, cwd) end
end

function M.bind_navigation(buf, navigate)
  local opts = { buffer = buf, silent = true, nowait = true }
  for _, direction in ipairs({ "h", "j", "k", "l" }) do
    vim.keymap.set("n", "<C-" .. direction .. ">", function()
      local win = api.nvim_get_current_win()
      if api.nvim_win_get_buf(win) == buf then navigate(win, direction) end
    end, opts)
  end
end

function M.mount(buf, win, open, prepare, highlights, zindex)
  local placeholder
  if not win or not api.nvim_win_is_valid(win) then
    -- Reserve the winbar before attaching a live terminal so its grid stays stable.
    if vim.bo[buf].buftype == "terminal" then placeholder = api.nvim_create_buf(false, true) end
    win = open(placeholder or buf)
  end
  prepare(win)
  if api.nvim_win_get_buf(win) ~= buf then api.nvim_win_set_buf(win, buf) end
  if placeholder then pcall(api.nvim_buf_delete, placeholder, { force = true }) end
  api.nvim_set_current_win(win)
  api.nvim_win_set_config(win, { zindex = zindex })
  M.configure_window(win, highlights)
  return win
end

function M.focus_input(win, buf, view_mode)
  local function focused()
    return api.nvim_get_current_win() == win and api.nvim_win_get_buf(win) == buf
  end
  if view_mode then
    vim.schedule(function() if focused() then vim.cmd.stopinsert() end end)
  elseif not M.is_scrolled(buf) then
    vim.defer_fn(function() if focused() then vim.cmd.startinsert() end end, 10)
  end
end

function M.is_closing_tile(win)
  return closing_tiles[vim.w[win].luanphan_view_anchor]
end

function M.bind_process(buf, group, process, on_close, replacement)
  local windows = require("luanphan.view_container.window")
  process.on_exit(buf, function()
    local win = vim.fn.win_findbuf(buf)[1]
    local anchor = win and vim.w[win].luanphan_view_anchor
    local action = win and (not anchor or win == api.nvim_get_current_win()) and replacement(buf)
    -- Give the replacement a chance to take focus before a resize rebuilds the panel.
    if action and anchor then closing_tiles[anchor] = true end
    on_close(buf)
    vim.schedule(function()
      if action and anchor then closing_tiles[anchor] = nil end
      local function showing()
        return win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf
      end
      if action and showing() then pcall(action) end
      if showing() then
        if anchor and win ~= anchor then
          pcall(api.nvim_win_close, win, true)
        else
          pcall(windows.close_window, win)
        end
      end
      if api.nvim_buf_is_valid(buf) then pcall(api.nvim_buf_delete, buf, { force = true }) end
    end)
  end)
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    once = true,
    callback = function()
      if type(vim.v.exiting) == "number" or not process.running(buf) then return end
      on_close(buf)
      vim.schedule(function() process.stop(buf) end)
    end,
  })
  M.bind_quit(buf, group, function(direct)
    if not process.running(buf) then return end
    local action = direct and replacement(buf)
    return function()
      if process.stop(buf) and action then pcall(action) end
    end
  end)
end

function M.bind_quit(buf, group, prepare)
  api.nvim_create_autocmd({ "CmdlineLeave", "QuitPre" }, {
    buffer = buf,
    group = group,
    callback = function(event)
      local typed = event.event == "CmdlineLeave"
      if typed then
        if vim.fn.getcmdtype() ~= ":" or vim.v.event.abort then return end
        local command = vim.trim(vim.fn.getcmdline()):gsub("!$", "")
        if command == "" or not vim.startswith("quit", command) then return end
      end
      local close = prepare(not typed)
      if not close then return end
      if typed then vim.cmd("let v:event.abort = v:true") end
      vim.schedule(function()
        if type(vim.v.exiting) ~= "number" then close() end
      end)
    end,
  })
end

return M
