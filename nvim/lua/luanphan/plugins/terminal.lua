local terms = {}

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
  get_term():toggle()
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
      { "<leader>tt", toggle_terminal, desc = "Toggle terminal" },
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
