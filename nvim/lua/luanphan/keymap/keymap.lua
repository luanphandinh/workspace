-- Basic keymaps and options
local lsp_restart = require("luanphan.lsp_restart")

vim.g.mapleader = " "
vim.g.maplocalleader = " "
vim.o.timeout = true
vim.o.timeoutlen = 500     -- time to wait for mapped sequence (ms)
vim.o.termguicolors = true -- enable true color support
vim.o.number = true
vim.o.relativenumber = true
vim.o.swapfile = false
vim.o.backup = false
vim.o.undodir = os.getenv("HOME") .. "/.vim/undodir"
vim.o.undofile = true
vim.o.hlsearch = true
vim.o.incsearch = true
-- Display options
vim.o.cursorline = true
vim.o.scrolloff = 8
vim.o.signcolumn = "yes" -- always show the signcolumn on the left side
vim.o.wrap = false       -- no soft-wrap by default; toggle with <leader>tW
vim.o.linebreak = true   -- when wrap is on, break at word boundaries, not mid-word
vim.o.cmdheight = 1

-- Statusline with LSP progress
vim.o.laststatus = 2
local lsp_progress_tokens = {} -- track active progress tokens

local function redraw_statusline()
  pcall(vim.cmd, "redrawstatus")
end

local function clear_lsp_progress_tokens()
  if next(lsp_progress_tokens) == nil then
    return
  end
  lsp_progress_tokens = {}
  redraw_statusline()
end

local function copilot_statusline()
  local ok, copilot = pcall(require, "luanphan.copilot_toggle")
  if not ok or type(copilot.statusline) ~= "function" then
    return ""
  end
  return copilot.statusline()
end

vim.api.nvim_create_autocmd("LspProgress", {
  callback = function(ev)
    local data = ev.data
    if not data or not data.params or not data.params.value then return end
    local val = data.params.value
    local client = vim.lsp.get_client_by_id(data.client_id)
    local name = client and client.name or ""
    local token = data.params.token
    local key = name .. ":" .. tostring(token)
    if val.kind == "end" then
      lsp_progress_tokens[key] = nil
    else
      local pct = val.percentage and (val.percentage .. "%%") or ""
      local title = val.title or ""
      local msg = val.message or ""
      lsp_progress_tokens[key] = string.format("[%s] %s %s %s", name, title, msg, pct)
    end
    redraw_statusline()
  end,
})

vim.api.nvim_create_autocmd("User", {
  pattern = "LuanphanWorktreeSwitchPre",
  callback = clear_lsp_progress_tokens,
})

vim.api.nvim_create_autocmd({ "DirChangedPre", "DirChanged" }, {
  callback = clear_lsp_progress_tokens,
})

function _G.statusline()
  local bt = vim.bo.buftype
  if bt == "nofile" or bt == "prompt" or bt == "terminal" then
    return " %f"
  end
  -- show the most recent active progress token
  local progress = ""
  for _, msg in pairs(lsp_progress_tokens) do
    progress = msg
  end
  local copilot = copilot_statusline()
  local parts = {
    " %f",                  -- filename
    "%m",                   -- modified flag
    "%r",                   -- readonly flag
    "  %{&filetype}",       -- filetype
    "%=",                   -- right align
    copilot ~= "" and (copilot .. "  ") or "",
    progress ~= "" and (progress .. "  ") or "",
    "%l:%c ",               -- line:col
  }
  return table.concat(parts)
end

vim.o.statusline = "%!v:lua.statusline()"

-- Navigation
vim.keymap.set("n", "n", "nzzzv", { noremap = true, silent = true })
vim.keymap.set("n", "N", "nzzzv", { noremap = true, silent = true })

vim.keymap.set("n", "<C-d>", "<C-d>zz", { noremap = true, silent = true })
vim.keymap.set("n", "<C-u>", "<C-u>zz", { noremap = true, silent = true })
vim.keymap.set("n", "J", "mzJ`z", { noremap = true, silent = true })
vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv")
vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv")

-- Clipboard / edit operators
vim.keymap.set("n", "<leader>y", "\"+y")
vim.keymap.set("v", "<leader>y", "\"+y")

vim.keymap.set("v", "<leader>d", "\"_d")
vim.keymap.set("x", "<leader>p", "\"_dP")

-- Window / terminal navigation
vim.keymap.set("n", "<C-f>", "<cmd>slient !tmux neww tmux-sessionizer<CR>")
vim.keymap.set("n", "<C-h>", "<C-w>h", { noremap = true, silent = true })
vim.keymap.set("n", "<C-l>", "<C-w>l", { noremap = true, silent = true })

-- |CTRL-W_o| like |:only| but keep nvim-tree / NERDTree sidebar if open
local function only_keep_tree()
  require("luanphan.win_only_tree").only_keep_tree()
end
vim.keymap.set("n", "<C-w>o", only_keep_tree, { desc = "Close other windows (keep NvimTree + current)" })
vim.keymap.set("n", "<C-w><C-o>", only_keep_tree, { desc = "Close other windows (keep NvimTree + current)" })

-- Terminal mode: escape terminal and switch windows
vim.keymap.set("t", "<C-h>", "<C-\\><C-n><C-w>h", { desc = "Exit terminal and go left" })
vim.keymap.set("t", "<C-l>", "<C-\\><C-n><C-w>l", { desc = "Exit terminal and go right" })
-- vim.keymap.set("t", "<C-j>", "<C-\\><C-n><C-w>j", { desc = "Exit terminal and go down" })
-- vim.keymap.set("t", "<C-k>", "<C-\\><C-n><C-w>k", { desc = "Exit terminal and go up" })
vim.keymap.set("t", "<Esc>", "<C-\\><C-n>", { desc = "Exit terminal mode" })
vim.keymap.set("t", "<C-]>", function()
  local job = vim.b.terminal_job_id
  if job then
    vim.fn.chansend(job, "\x1b")
  end
end, { desc = "Send Esc to terminal process" })

-- Search
vim.keymap.set("n", "<leader>t1", function()
  require("luanphan.telescope_grep_opts").toggle_case_sensitive()
end, { desc = "Live grep case sensitivity" })
vim.keymap.set("n", "<leader>t2", function()
  require("luanphan.telescope_grep_opts").toggle_regex()
end, { desc = "Live grep regex" })

-- Diagnostics
vim.keymap.set("n", "<leader>d", function()
  vim.diagnostic.open_float(nil, { focus = false })
end, { desc = "Show diagnostic at line" })

-- Buffers
vim.keymap.set("n", "<leader>kw", function()
  require("luanphan.buffer_only").close_other_file_buffers()
end, { desc = "Close other files (keep active buffer, tree, terminals, AI)" })
vim.keymap.set("n", "<leader>kW", function()
  require("luanphan.buffer_only").close_other_file_buffers({ force = true })
end, { desc = "Close other files (!) discard unsaved in closed buffers" })

-- Config
-- Full reload: luafile init (not :source — that is for Vimscript; init.lua needs :luafile).
-- Some plugins cache state after setup; restart Neovim if maps stay wrong.
vim.keymap.set("n", "<leader>rc", function()
  for k in pairs(package.loaded) do
    if k:match("^luanphan") then
      package.loaded[k] = nil
    end
  end

  local init = vim.fn.expand("$MYVIMRC")
  if init == "" then
    vim.notify("$MYVIMRC is empty", vim.log.levels.ERROR)
    return
  end

  if init:lower():match("%.lua$") then
    vim.cmd("luafile " .. vim.fn.fnameescape(init))
  else
    vim.cmd("source " .. vim.fn.fnameescape(init))
  end

  print("Config reloaded!")
end, { desc = "Config" })

-- LSP
-- LSP: use vim.lsp.enable(false) then enable(true) — see :help lsp-restart
vim.keymap.set("n", "<leader>rl", function()
  lsp_restart.restart_buffer()
end, { desc = "LSP" })

-- AI
vim.keymap.set("n", "<leader>tc", function()
  require("luanphan.copilot_toggle").toggle()
end, { desc = "Copilot" })

-- Go test keymaps (only in Go files)
vim.api.nvim_create_autocmd("FileType", {
  pattern = "go",
  callback = function()
    vim.keymap.set("n", "<leader>gtc", function()
      require("luanphan.plugins.go").run_go_test_at_cursor()
    end, { buffer = true, desc = "Run Go test at cursor" })
    vim.keymap.set("n", "<leader>gtf", function()
      require("luanphan.plugins.go").run_go_test_file()
    end, { buffer = true, desc = "Run Go test file" })
    vim.keymap.set("n", "<leader>gtp", function()
      require("luanphan.plugins.go").run_go_test_package()
    end, { buffer = true, desc = "Run Go test package" })
  end,
})

-- Command to create empty buffer with filetype
-- Usage: :New go, :New lua, :New json, etc.
vim.api.nvim_create_user_command("New", function(opts)
  vim.cmd("enew")
  vim.bo.filetype = opts.args
end, { nargs = 1, desc = "Create new buffer with filetype" })

-- Files
vim.keymap.set("n", "<leader>fn", "<cmd>enew<cr>", { desc = "New buffer" })

local function toggle_file_diff()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_get_option_value("diff", { win = win }) then
      vim.cmd("windo diffoff")
      return
    end
  end

  vim.cmd("windo diffthis")
end

vim.keymap.set("n", "<leader>td", toggle_file_diff, { desc = "File diff" })

vim.keymap.set("n", "<leader>fp", "<cmd>MarkdownPreviewToggle<cr>", { desc = "Preview Markdown in browser" })

vim.keymap.set("n", "<leader>fs", function()
  if vim.fn.bufname() == "" then
    -- New buffer without name - prompt for filename
    local filename = vim.fn.input("Save as: ")
    if filename ~= "" then
      vim.cmd("noautocmd write " .. vim.fn.fnameescape(filename))
    end
  else
    vim.cmd("noautocmd write")
  end
end, { desc = "Save current file" })

vim.keymap.set("n", "<leader>fS", "<cmd>wa<cr>", { desc = "Save all files" })

-- Force-reload the current buffer from disk. `:edit!` re-reads the file and
-- discards any unsaved in-buffer changes — useful when an external tool
-- (formatter, codegen, git checkout) has rewritten the file on disk.
vim.keymap.set("n", "<leader>fL", "<cmd>edit!<cr>", { desc = "Reload from disk" })

-- UI
vim.keymap.set("n", "<leader>tW", function()
  local enabled = not vim.wo.wrap
  vim.o.wrap = enabled

  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      vim.wo[win].wrap = enabled
    end
  end

  vim.notify("wrap: " .. (enabled and "on" or "off") .. " (all windows)", vim.log.levels.INFO)
end, { desc = "Word wrap (all windows)" })
