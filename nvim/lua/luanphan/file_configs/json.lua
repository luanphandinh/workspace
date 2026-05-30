local M = {}

local format_group = vim.api.nvim_create_augroup("LuanphanJsonFormat", { clear = false })

local function format_json(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if vim.fn.executable("jq") == 0 then
    vim.notify("jq: not on PATH", vim.log.levels.ERROR)
    return
  end
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_buf(win) == buf and vim.api.nvim_win_get_cursor(win) or nil
  local input = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local out = vim.fn.systemlist({ "jq", "." }, input)
  if vim.v.shell_error ~= 0 then
    local msg = type(out) == "table" and table.concat(out, "\n") or tostring(out)
    vim.notify("jq: " .. (msg ~= "" and msg or "format failed"), vim.log.levels.ERROR)
    return
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
  if cursor then
    pcall(vim.api.nvim_win_set_cursor, win, cursor)
  end
end

local function attach(buf)
  if vim.b[buf].luanphan_json_configured then
    return
  end
  vim.b[buf].luanphan_json_configured = true

  vim.api.nvim_create_autocmd("BufWritePre", {
    group = format_group,
    buffer = buf,
    callback = function(ev)
      format_json(ev.buf)
    end,
  })
  vim.keymap.set("n", "<leader>kf", function()
    format_json(buf)
  end, { buffer = buf, desc = "Format" })
end

function M.setup()
  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("LuanphanJsonFileConfig", { clear = true }),
    pattern = "json",
    callback = function(ev)
      attach(ev.buf)
    end,
  })

  if vim.bo.filetype == "json" then
    attach(0)
  end
end

return M
