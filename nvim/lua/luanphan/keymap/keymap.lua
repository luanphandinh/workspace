-- Basic keymaps and options
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

-- Terminal mode: escape terminal and switch windows
vim.keymap.set("t", "<C-h>", "<C-\\><C-n><C-w>h", { desc = "Exit terminal and go left" })
vim.keymap.set("t", "<C-l>", "<C-\\><C-n><C-w>l", { desc = "Exit terminal and go right" })
vim.keymap.set("t", "<C-j>", "<C-\\><C-n><C-w>j", { desc = "Exit terminal and go down" })
vim.keymap.set("t", "<C-k>", "<C-\\><C-n><C-w>k", { desc = "Exit terminal and go up" })
vim.keymap.set("t", "<Esc>", "<C-\\><C-n>", { desc = "Exit terminal mode" })

vim.keymap.set("n", "<leader>d", function()
  vim.diagnostic.open_float(nil, { focus = false })
end, { desc = "Show diagnostic at line" })

-- Reload config
vim.keymap.set("n", "<leader>rr", function()
  -- Clear loaded modules from cache
  for k in pairs(package.loaded) do
    if k:match("^luanphan") then
      package.loaded[k] = nil
    end
  end
  -- Source the config
  vim.cmd("source $MYVIMRC")

  -- Restart LSP servers for current buffer
  vim.lsp.stop_client(vim.lsp.get_clients({ bufnr = 0 }))
  vim.defer_fn(function()
    vim.cmd("edit") -- Re-trigger LSP attach
  end, 100)

  print("Config reloaded! LSP restarted.")
end, { desc = "Reload config & restart LSP" })

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
