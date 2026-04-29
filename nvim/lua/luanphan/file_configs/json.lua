-- Run `jq .` against the current buffer. On success, replace the buffer
-- contents with the formatted output and restore cursor. On failure (invalid
-- JSON, jq missing, …) leave the buffer untouched and report the error via
-- vim.notify so it lands in the message area under the statusline instead of
-- clobbering the file.
local function format_json()
  if vim.fn.executable("jq") == 0 then
    vim.notify("jq: not on PATH", vim.log.levels.ERROR)
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local input = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  local out = vim.fn.systemlist({ "jq", "." }, input)
  if vim.v.shell_error ~= 0 then
    local msg = type(out) == "table" and table.concat(out, "\n") or tostring(out)
    vim.notify("jq: " .. (msg ~= "" and msg or "format failed"), vim.log.levels.ERROR)
    return
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, out)
  pcall(vim.api.nvim_win_set_cursor, 0, cursor)
end

vim.api.nvim_create_autocmd("FileType", {
  pattern = "json",
  callback = function()
    vim.api.nvim_create_autocmd("BufWritePre", {
      buffer = 0,
      callback = format_json,
    })
    vim.keymap.set("n", "<leader>fj", format_json, { buffer = true, desc = "Format JSON" })
  end,
})
