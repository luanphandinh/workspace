-- Basic keymaps and options
vim.g.mapleader = " "
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

vim.keymap.set("n", "<leader>t", function()
  vim.cmd("vsplit | terminal")
end, { noremap = true, silent = true })

vim.keymap.set("n", "<leader>of", function()
  require("telescope.builtin").lsp_document_symbols({
    symbols = { "Function", "Method" },
    symbol_width = 80,
    previewer = false,
    layout_config = {
      width = 0.5,
      height = 0.5,
    },
  })
end, { noremap = true, silent = true })

vim.keymap.set("n", "<leader>d", function()
  vim.diagnostic.open_float(nil, { focus = false })
end, { desc = "Show diagnostic at line" })

vim.keymap.set("n", "<leader>gt", function()
  local go = require("luanphan.plugins.go")
  go.run_go_test_at_cursor()
end)
