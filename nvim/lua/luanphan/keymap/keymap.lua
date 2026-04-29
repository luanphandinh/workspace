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
vim.o.wrap = false       -- no soft-wrap by default; toggle with <leader>tw
vim.o.linebreak = true   -- when wrap is on, break at word boundaries, not mid-word

-- Statusline with LSP progress
vim.o.laststatus = 2
local lsp_progress_tokens = {} -- track active progress tokens

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
    vim.cmd("redrawstatus")
  end,
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
  local parts = {
    " %f",                  -- filename
    "%m",                   -- modified flag
    "%r",                   -- readonly flag
    "  %{&filetype}",       -- filetype
    "%=",                   -- right align
    progress ~= "" and (progress .. "  ") or "",
    "%l:%c ",               -- line:col
  }
  return table.concat(parts)
end

vim.o.statusline = "%!v:lua.statusline()"
-- keymaps
vim.keymap.set("n", "n", "nzzzv", { noremap = true, silent = true })
vim.keymap.set("n", "N", "nzzzv", { noremap = true, silent = true })

vim.keymap.set("n", "<C-d>", "<C-d>zz", { noremap = true, silent = true })
vim.keymap.set("n", "<C-u>", "<C-u>zz", { noremap = true, silent = true })
vim.keymap.set("n", "J", "mzJ`z", { noremap = true, silent = true })
vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv")
vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv")

vim.keymap.set("n", "<leader>y", "\"+y")
vim.keymap.set("v", "<leader>y", "\"+y")

vim.keymap.set("n", "<leader>d", "\"_d")
vim.keymap.set("v", "<leader>d", "\"_d")
vim.keymap.set("x", "<leader>p", "\"_dP")

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

vim.keymap.set("n", "<leader>p", "<cmd>Telescope find_files<cr>")
vim.keymap.set("n", "<leader>gb", function()
  require("telescope.builtin").git_branches()
end, { desc = "Git: pick branch (checkout on <CR>)" })
vim.keymap.set("n", "g/", function()
  require("luanphan.telescope_grep_opts").live_grep()
end, { desc = "Telescope live_grep (honors <leader>t1 / t2 ripgrep toggles)" })

vim.keymap.set("n", "<leader>t1", function()
  require("luanphan.telescope_grep_opts").toggle_case_sensitive()
end, { desc = "live_grep: toggle strict case vs ignore-case (default: ignore-case on)" })
vim.keymap.set("n", "<leader>t2", function()
  require("luanphan.telescope_grep_opts").toggle_regex()
end, { desc = "live_grep: toggle regex vs fixed-string (default: fixed-string on)" })

vim.keymap.set("n", "<leader>sr", function()
  require("luanphan.qf_replace").prompt_cfdo_substitute()
end, { desc = "Quickfix: replace in all listed files (use g/ then <C-q> first)" })
vim.keymap.set("n", "<leader>lf", "<cmd>Telescope buffers<cr>", { desc = "Telescope: buffers" })

vim.keymap.set("n", "<leader>d", function()
  vim.diagnostic.open_float(nil, { focus = false })
end, { desc = "Show diagnostic at line" })

-- Markdown: floating `glow` preview (toggle). Requires `glow` on PATH.
vim.keymap.set("n", "<leader>fp", function()
  require("luanphan.glow_preview").toggle()
end, { desc = "Markdown: toggle glow preview (float)" })

-- Close other file buffers only (keep NvimTree, terminals, AI agent terminals).
vim.keymap.set("n", "<leader>kw", function()
  require("luanphan.buffer_only").close_other_file_buffers()
end, { desc = "Buffer: close other files (keep active buffer, tree, terminals, AI)" })
vim.keymap.set("n", "<leader>kW", function()
  require("luanphan.buffer_only").close_other_file_buffers({ force = true })
end, { desc = "Buffer: close other files (!) discard unsaved in closed buffers" })

-- Full reload: luafile init (not :source — that is for Vimscript; init.lua needs :luafile).
-- Note: re-running init.lua also re-enters Packer startup; some plugins cache state — restart Neovim if maps stay wrong.
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
end, { desc = "Reload config (full init.lua)" })

-- LSP: use vim.lsp.enable(false) then enable(true) — see :help lsp-restart
vim.keymap.set("n", "<leader>rl", function()
  lsp_restart.restart_all()
end, { desc = "LspRestart: full LSP restart" })

vim.keymap.set("n", "<leader>rg", function()
  lsp_restart.restart_gopls()
end, { desc = "GoplsRestart: full gopls stop + re-attach all Go buffers" })

vim.keymap.set("n", "<leader>rb", function()
  lsp_restart.restart_buffer()
end, { desc = "LspRestartBuffer: this buffer / recover attach" })

vim.keymap.set("n", "<leader>tc", function()
  require("luanphan.copilot_toggle").toggle()
end, { desc = "Copilot: load if needed, then toggle on/off" })

-- List all symbols in current file
vim.keymap.set("n", "gs", function()
  require("telescope.builtin").lsp_document_symbols({
    previewer = false,
    symbol_width = 80,
    layout_strategy = "vertical",
    layout_config = {
      width = 0.5,
      height = 0.6,
    },
  })
end, { desc = "List symbols in file" })

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

-- Keybindings for file/buffer management
vim.keymap.set("n", "<leader>fn", "<cmd>enew<cr>", { desc = "New file" })

vim.keymap.set("n", "<leader>fs", function()
  if vim.fn.bufname() == "" then
    -- New buffer without name - prompt for filename
    local filename = vim.fn.input("Save as: ")
    if filename ~= "" then
      vim.cmd("w " .. vim.fn.fnameescape(filename))
    end
  else
    vim.cmd("w")
  end
end, { desc = "Save file" })

vim.keymap.set("n", "<leader>fS", "<cmd>wa<cr>", { desc = "Save all files" })

-- Force-reload the current buffer from disk. `:edit!` re-reads the file and
-- discards any unsaved in-buffer changes — useful when an external tool
-- (formatter, codegen, git checkout) has rewritten the file on disk.
vim.keymap.set("n", "<leader>fl", "<cmd>edit!<cr>", { desc = "Reload File Content From Disk" })

vim.keymap.set("n", "<leader>tw", function()
  vim.wo.wrap = not vim.wo.wrap
  vim.notify("wrap: " .. (vim.wo.wrap and "on" or "off"), vim.log.levels.INFO)
end, { desc = "Toggle word wrap (window-local)" })

vim.keymap.set("n", "<leader>ft", function()
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local filetypes = { "json", "sql", "txt", "md", "go", "lua", "python", "javascript", "yaml", "html", "css" }

  pickers
    .new({}, {
      prompt_title = "Set Filetype",
      finder = finders.new_table({ results = filetypes }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            vim.bo.filetype = selection[1]
          end
        end)
        return true
      end,
    })
    :find()
end, { desc = "Set filetype" })

-- Diff mode keybindings
vim.keymap.set("n", "<leader>df", "<cmd>windo diffthis<cr>", { desc = "Diff compare (vertical split)" })
vim.keymap.set("n", "<leader>dF", "<cmd>windo diffoff<cr>", { desc = "Diff off" })
vim.keymap.set("n", "<leader>do", "<cmd>diffget<cr>", { desc = "Diff obtain (get from other)" })
vim.keymap.set("n", "<leader>dp", "<cmd>diffput<cr>", { desc = "Diff put (send to other)" })
