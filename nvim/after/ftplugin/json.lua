local buf = vim.api.nvim_get_current_buf()
local format_group = vim.api.nvim_create_augroup("LuanphanJsonFormat", { clear = false })

local function format_json()
  if vim.fn.executable("jq") == 0 then
    vim.notify("jq: not on PATH", vim.log.levels.ERROR)
    return
  end

  local win = vim.fn.bufwinid(buf)
  local cursor = win ~= -1 and vim.api.nvim_win_get_cursor(win) or nil
  local input = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local out = vim.fn.systemlist({ "jq", "." }, input)
  if vim.v.shell_error ~= 0 then
    local message = type(out) == "table" and table.concat(out, "\n") or tostring(out)
    vim.notify("jq: " .. (message ~= "" and message or "format failed"), vim.log.levels.ERROR)
    return
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
  if cursor then
    pcall(vim.api.nvim_win_set_cursor, win, cursor)
  end
end

vim.api.nvim_clear_autocmds({ group = format_group, buffer = buf })
vim.api.nvim_create_autocmd("BufWritePre", {
  group = format_group,
  buffer = buf,
  callback = format_json,
})
vim.keymap.set("n", "<leader>kf", format_json, { buffer = buf, desc = "Format" })
