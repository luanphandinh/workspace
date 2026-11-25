local M = {}
local api = vim.api

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

return M
