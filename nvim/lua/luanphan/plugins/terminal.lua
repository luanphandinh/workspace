local terms = {}

local function close_agent_floats()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg.relative and cfg.relative ~= "" then
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.b[buf].luanphan_persist_term and not vim.b[buf].luanphan_toggleterm then
          pcall(vim.api.nvim_win_close, win, false)
        end
      end
    end
  end
end

local function get_term()
  local Terminal = require("toggleterm.terminal").Terminal
  local cwd = vim.fn.getcwd()
  local t = terms[cwd]
  if t and t.bufnr and vim.api.nvim_buf_is_valid(t.bufnr) then
    return t
  end
  t = Terminal:new({
    dir = cwd,
    direction = "vertical",
    close_on_exit = false,
    on_open = function(term)
      pcall(function()
        vim.b[term.bufnr].luanphan_persist_term = true
        vim.b[term.bufnr].luanphan_toggleterm = true
      end)
    end,
  })
  terms[cwd] = t
  return t
end

local function toggle_terminal()
  local term = get_term()
  if not term:is_open() then
    close_agent_floats()
  end
  term:toggle()
end

local function hide_current()
  local cwd = vim.fn.getcwd()
  local t = terms[cwd]
  if t and t.bufnr and vim.api.nvim_buf_is_valid(t.bufnr) and t:is_open() then
    t:close()
  end
end

local function setup_terminal_autocmds()
  vim.api.nvim_create_autocmd("TermOpen", {
    pattern = "term://*",
    group = vim.api.nvim_create_augroup("LuanphanTerminal", { clear = true }),
    callback = function(ev)
      vim.keymap.set("t", "<esc>", [[<c-\><c-n>]], { buffer = ev.buf })
      vim.defer_fn(function()
        if vim.api.nvim_get_current_buf() == ev.buf and vim.bo[ev.buf].buftype == "terminal" then
          vim.cmd("startinsert")
        end
      end, 10)
    end,
  })
end

return {
  -- Toggleable terminal, scoped per worktree (cwd). Switching worktrees hides the
  -- current terminal; toggling again in a new cwd spawns a fresh one; switching
  -- back re-shows the previous one.
  {
    "akinsho/toggleterm.nvim",
    keys = {
      { "<leader>tt", toggle_terminal, desc = "Terminal" },
    },
    init = setup_terminal_autocmds,
    config = function()
      require("toggleterm").setup({
        size = 100,
        direction = "vertical", -- opens on the right
        shade_terminals = false,
        persist_size = true,
        persist_mode = false,
        -- Keep the pane after the shell job exits so output stays visible (scroll with Esc then j/k).
        close_on_exit = false,
        auto_scroll = true,
      })

      vim.api.nvim_create_autocmd("User", {
        pattern = "LuanphanWorktreeSwitchPre",
        group = vim.api.nvim_create_augroup("LuanphanToggletermWorktreePre", { clear = true }),
        callback = hide_current,
      })

      vim.api.nvim_create_autocmd("DirChangedPre", {
        group = vim.api.nvim_create_augroup("LuanphanToggletermDirPre", { clear = true }),
        callback = hide_current,
      })
    end,
  },
}
