local M = {}

function M.open(path, opts)
  opts = opts or {}
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)

  local existing = vim.fn.bufwinid(buf)
  if existing ~= -1 then
    vim.api.nvim_set_current_win(existing)
    return
  end

  local width = math.max(40, math.floor(vim.o.columns * 0.5))
  local height = math.max(8, math.floor(vim.o.lines * 0.4))
  width = math.min(width, vim.o.columns - 4)
  height = math.min(height, vim.o.lines - 4)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "single",
    title = " " .. (opts.title or "Settings") .. " ",
    title_pos = "center",
  })

  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = opts.filetype or "toml"
  vim.wo[win].number = true
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = false

  local closing = false
  local function save_and_close()
    if closing then
      return
    end

    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
      local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
        vim.cmd("silent write")
      end)
      if not ok then
        vim.notify("Could not save settings: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
    end

    closing = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.keymap.set("n", "q", save_and_close, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", save_and_close, { buffer = buf, silent = true })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = vim.api.nvim_create_augroup("LuanphanSettingsEditor", { clear = false }),
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        if not closing and vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() ~= win then
          save_and_close()
        end
      end)
    end,
  })
end

return M
