-- Floating terminal preview of the current file with `glow` (https://github.com/charmbracelet/glow).
-- Shows on-disk content; save the buffer to refresh.

local M = {}

local preview_win ---@type integer?

local function is_markdown_buf()
  local ft = vim.bo.filetype
  if ft == "markdown" or ft == "rmd" then
    return true
  end
  local n = vim.api.nvim_buf_get_name(0):lower()
  return n:match("%.mdc?$") ~= nil or n:match("%.markdown$") ~= nil
end

function M.toggle()
  if preview_win and vim.api.nvim_win_is_valid(preview_win) then
    local buf = vim.api.nvim_win_get_buf(preview_win)
    vim.api.nvim_win_close(preview_win, true)
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "terminal" then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    preview_win = nil
    return
  end
  preview_win = nil

  if not is_markdown_buf() then
    vim.notify("glow preview: only for Markdown buffers", vim.log.levels.WARN)
    return
  end

  local path = vim.fn.expand("%:p")
  if path == "" then
    vim.notify("glow preview: need a saved file path", vim.log.levels.WARN)
    return
  end

  if vim.fn.executable("glow") == 0 then
    vim.notify("glow preview: install `glow` — https://github.com/charmbracelet/glow", vim.log.levels.ERROR)
    return
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  local w = math.max(40, math.floor(vim.o.columns * 0.88))
  local h = math.max(12, math.floor(vim.o.lines * 0.88))
  local row = math.max(0, math.floor((vim.o.lines - h) / 2))
  local col = math.max(0, math.floor((vim.o.columns - w) / 2))

  local win_opts = {
    relative = "editor",
    width = w,
    height = h,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
  }
  if vim.fn.has("nvim-0.9") == 1 then
    win_opts.title = " glow "
    win_opts.title_pos = "center"
  end

  preview_win = vim.api.nvim_open_win(bufnr, true, win_opts)

  vim.fn.termopen({ "glow", path }, { cwd = vim.fn.fnamemodify(path, ":h") })

  vim.keymap.set("n", "<leader>fp", function()
    M.toggle()
  end, { buffer = bufnr, silent = true, desc = "Close glow preview" })
  vim.keymap.set(
    "t",
    "<leader>fp",
    "<C-\\><C-n><cmd>lua require('luanphan.glow_preview').toggle()<cr>",
    { buffer = bufnr, silent = true, desc = "Close glow preview" }
  )
end

return M
