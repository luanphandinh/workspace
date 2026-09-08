local terms = {}
local active_terms = {}
local terminal_container

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

local function cwd_terms(cwd)
  local valid = {}
  for _, term in ipairs(terms[cwd] or {}) do
    if term.bufnr and vim.api.nvim_buf_is_valid(term.bufnr) then
      valid[#valid + 1] = term
    end
  end
  terms[cwd] = valid
  if active_terms[cwd] and not vim.tbl_contains(valid, active_terms[cwd]) then
    active_terms[cwd] = nil
  end
  return valid
end

local function save_terminal_view(term)
  if not term or not term.window or not vim.api.nvim_win_is_valid(term.window) then
    return
  end
  local ok, view = pcall(vim.api.nvim_win_call, term.window, vim.fn.winsaveview)
  if ok then
    vim.b[term.bufnr].luanphan_terminal_view = {
      follow = view.lnum >= vim.api.nvim_buf_line_count(term.bufnr),
      view = view,
    }
  end
end

local function restore_terminal_view(term)
  local saved = vim.b[term.bufnr].luanphan_terminal_view
  if type(saved) == "table" and saved.follow == false and type(saved.view) == "table" then
    vim.schedule(function()
      if term.window and vim.api.nvim_win_is_valid(term.window) and vim.api.nvim_win_get_buf(term.window) == term.bufnr then
        pcall(vim.api.nvim_win_call, term.window, function()
          vim.fn.winrestview(saved.view)
        end)
      end
    end)
    return
  end

  vim.defer_fn(function()
    if term.window and vim.api.nvim_win_is_valid(term.window) and vim.api.nvim_get_current_win() == term.window then
      vim.cmd("startinsert")
    end
  end, 10)
end

local function close_open_terms(cwd, except)
  for _, term in ipairs(cwd_terms(cwd)) do
    if term ~= except and term:is_open() then
      term:close()
    end
  end
end

local function new_terminal(cwd)
  cwd = cwd or vim.fn.getcwd()
  close_agent_floats()
  close_open_terms(cwd)

  local Terminal = require("toggleterm.terminal").Terminal
  local term = Terminal:new({
    dir = cwd,
    direction = "vertical",
    close_on_exit = false,
    on_open = function(term)
      pcall(function()
        vim.b[term.bufnr].luanphan_persist_term = true
        vim.b[term.bufnr].luanphan_toggleterm = true
        vim.b[term.bufnr].luanphan_toggleterm_cwd = cwd
      end)
      active_terms[cwd] = term
      terminal_container:attach(term.window, term.bufnr, "terminal:" .. term.id, cwd)
      restore_terminal_view(term)
    end,
    on_close = function(term)
      save_terminal_view(term)
    end,
  })
  terms[cwd] = terms[cwd] or {}
  terms[cwd][#terms[cwd] + 1] = term
  active_terms[cwd] = term
  term:open()
  return term
end

local function show_terminal(term, cwd)
  if not term then
    return new_terminal(cwd)
  end
  close_agent_floats()
  close_open_terms(cwd, term)
  active_terms[cwd] = term
  if term:is_open() then
    term:focus()
    terminal_container:attach(term.window, term.bufnr, "terminal:" .. term.id, cwd)
  else
    term:open()
  end
  return term
end

local function active_terminal(cwd)
  local available = cwd_terms(cwd)
  return active_terms[cwd] or available[#available]
end

local function toggle_terminal()
  local cwd = vim.fn.getcwd()
  for _, term in ipairs(cwd_terms(cwd)) do
    if term:is_open() then
      active_terms[cwd] = term
      close_open_terms(cwd)
      return
    end
  end
  show_terminal(active_terminal(cwd), cwd)
end

local function hide_current()
  local cwd = vim.fn.getcwd()
  close_open_terms(cwd)
end

terminal_container = require("luanphan.view_container").create({
  context = vim.fn.getcwd,
  tabs = function(cwd)
    local available = cwd_terms(cwd)
    local tabs = {}
    for index, term in ipairs(available) do
      tabs[#tabs + 1] = {
        id = "terminal:" .. term.id,
        label = #available > 1 and ("terminal " .. index) or "terminal",
        bufnr = term.bufnr,
        term = term,
      }
    end
    return tabs
  end,
  activate = function(tab)
    show_terminal(tab.term, vim.b[tab.bufnr].luanphan_toggleterm_cwd or vim.fn.getcwd())
  end,
  new = new_terminal,
  cycle_desc = "Next terminal",
  new_desc = "New terminal",
})

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
