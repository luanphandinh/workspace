local api = vim.api
local shell = require("luanphan.view_container.shell")

return require("luanphan.view_container.shell_panel").create({
  settings = "floating_terminal",
  augroup = "LuanphanFloatingTerminal",
  close_on_exit = true,
  spawn = function(cwd)
    local buf = api.nvim_create_buf(false, true)
    vim.b[buf].luanphan_persist_term = true
    vim.b[buf].luanphan_floating_terminal = true
    local started, job = pcall(api.nvim_buf_call, buf, function()
      return vim.fn.jobstart(shell.command(), { term = true, cwd = cwd })
    end)
    if not started or job <= 0 then
      api.nvim_buf_delete(buf, { force = true })
      vim.notify("Could not start the floating terminal shell", vim.log.levels.ERROR)
      return
    end
    require("luanphan.terminal_references").attach(buf, cwd)
    return { bufnr = buf }
  end,
})
