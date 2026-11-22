local M = {}
local panel

local function integrated()
  if panel then return panel end
  panel = require("luanphan.terminal.panel").create({
    settings = "terminal_split",
    augroup = "LuanphanIntegratedTerminal",
    docked = true,
    on_open = function()
      local floating = package.loaded["luanphan.terminal.floating"]
      if floating then floating.hide() end
      require("luanphan.agents.main").hide()
    end,
    spawn = function(cwd, opts)
      opts = opts or {}
      local Terminal = require("toggleterm.terminal").Terminal
      local term = Terminal:new({ dir = opts.dir or cwd, cmd = opts.cmd, display_name = opts.label,
        direction = "vertical", close_on_exit = false })
      term:spawn()
      vim.b[term.bufnr].luanphan_persist_term = true
      vim.b[term.bufnr].luanphan_toggleterm = true
      vim.b[term.bufnr].luanphan_toggleterm_cwd = cwd
      require("luanphan.terminal_references").attach(term.bufnr, opts.dir or cwd)
      return { bufnr = term.bufnr, label = opts.label or "terminal", term = term }
    end,
  })
  return panel
end

local function setup_terminal_autocmds()
  vim.api.nvim_create_autocmd("TermOpen", {
    pattern = "term://*",
    group = vim.api.nvim_create_augroup("LuanphanTerminal", { clear = true }),
    callback = function(ev)
      vim.keymap.set("t", "<esc>", [[<c-\><c-n>]], { buffer = ev.buf })
      vim.defer_fn(function()
        if vim.api.nvim_get_current_buf() == ev.buf
            and vim.bo[ev.buf].buftype == "terminal"
            and not vim.b[ev.buf].luanphan_persist_term
            and not vim.b[ev.buf].luanphan_toggleterm then
          vim.cmd("startinsert")
        end
      end, 10)
    end,
  })
end

function M.run_command(command, cwd, label)
  require("lazy").load({ plugins = { "toggleterm.nvim" } })
  local result = integrated().new_tab({ cmd = command, dir = cwd, label = label })
  return result and result.term
end

M.spec = {
  {
    "luanphan-floating-terminal",
    virtual = true,
    keys = {
      { "<leader>j", function() require("luanphan.terminal.floating").toggle() end, desc = "Floating terminal" },
    },
  },
  {
    "akinsho/toggleterm.nvim",
    keys = {
      { "<leader>tt", function() integrated().toggle() end, desc = "Terminal" },
    },
    init = setup_terminal_autocmds,
    config = function()
      require("toggleterm").setup({
        size = 100,
        direction = "vertical",
        shade_terminals = false,
        start_in_insert = false,
        persist_mode = false,
        close_on_exit = false,
      })
    end,
  },
}

return M
