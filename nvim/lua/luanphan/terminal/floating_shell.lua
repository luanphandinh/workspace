local api = vim.api

return require("luanphan.view_container.shell_panel").create({
  settings = "floating_terminal",
  augroup = "LuanphanFloatingTerminal",
  close_on_exit = true,
  on_open = function()
    require("luanphan.agents.main").hide()
    require("luanphan.view_container.editor").remember_source(api.nvim_get_current_win())
  end,
  spawn = function(cwd)
    local buf = api.nvim_create_buf(false, true)
    vim.b[buf].luanphan_persist_term = true
    vim.b[buf].luanphan_floating_terminal = true
    local started, job = pcall(api.nvim_buf_call, buf, function()
      return vim.fn.jobstart({ vim.o.shell, "-i" }, { term = true, cwd = cwd })
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
