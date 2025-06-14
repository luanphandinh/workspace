-- Auto-install packer if not installed
local ensure_packer = function()
  local fn = vim.fn
  local install_path = fn.stdpath("data") .. "/site/pack/packer/start/packer.nvim"
  if fn.empty(fn.glob(install_path)) > 0 then
    fn.system({
      "git",
      "clone",
      "--depth",
      "1",
      "https://github.com/wbthomason/packer.nvim",
      install_path,
    })
    vim.cmd([[packadd packer.nvim]])
    return true
  end
  return false
end

ensure_packer()

-- Plugins
require("packer").startup(function(use)
  use "wbthomason/packer.nvim"

  -- File explorer
  use {
    "nvim-tree/nvim-tree.lua",
    -- requires = { "nvim-tree/nvim-web-devicons" },
    config = function()
      require("nvim-tree").setup()

      vim.keymap.set("n", "<leader>b", function()
        require("nvim-tree.api").tree.toggle(false, true)
      end)

      vim.keymap.set("n", "<leader>e", function()
        -- If tree is already open and focused, switch back
        if vim.bo.filetype == "NvimTree" then
          vim.cmd("wincmd p") -- switch to previous window
        else
          require("nvim-tree.api").tree.find_file({ open = true, focus = true })
        end
      end, { noremap = true, silent = true })
    end,
  }

  -- Fuzzy finder
  -- Telescope with fzf fuzzy match
  use {
    "nvim-telescope/telescope.nvim",
    requires = { "nvim-lua/plenary.nvim" },
    config = function()
      require("telescope").setup({
        defaults = {
          sorting_strategy = "ascending",
          layout_config = {
            prompt_position = "top",
            preview_cutoff = 1,
          },
          preview = {
            treesitter = false,
          },
        },
        extensions = {
          fzf = {
            fuzzy = true,                   -- enable fuzzy matching
            override_generic_sorter = true, -- override the default sorter
            override_file_sorter = true,
          }
        }
      })
      vim.keymap.set("n", "<leader>f", "<cmd>Telescope find_files<cr>")
      vim.keymap.set("n", "g/", "<cmd>Telescope live_grep<cr>")
    end,
  }

  -- use {
  --   "nvim-telescope/telescope-fzf-native.nvim",
  --   run = "make",
  --   cond = vim.fn.executable("make") == 1,
  --   config = function()
  --     require("telescope").load_extension("fzf")
  --   end,
  -- }

  -- Gruvbox theme
  use {
    "ellisonleao/gruvbox.nvim",
    config = function()
      require("gruvbox").setup({
        bold = false,
      })
      vim.o.background = "dark"
      vim.cmd([[colorscheme gruvbox]])
    end,
  }

  -- auto pair brackets
  use {
    "windwp/nvim-autopairs",
    config = function()
      require("nvim-autopairs").setup({
        check_ts = true, -- enable Treesitter integration for smarter pairing
      })
    end
  }

  -- comment plugin
  use {
    "numToStr/Comment.nvim",
    config = function()
      require("Comment").setup()
    end
  }

  -- buffer line
  use {
    'akinsho/bufferline.nvim',
    version = "*",
    dependencies = 'nvim-tree/nvim-web-devicons',
    config = function()
      require("bufferline").setup()
      vim.opt.termguicolors = true
    end
  }

  -- LSP Config for Go
  use {
    "neovim/nvim-lspconfig",
    config = function()
      local on_attach_lsp = function(client, bufnr)
        local opts = { noremap = true, silent = true, buffer = bufnr }
        local builtin = require("telescope.builtin") -- Use telescope for nicer view of gd, gi, gr

        local previewOpts = {
          initial_mode = "normal",
          layout_strategy = "vertical",
        }

        vim.keymap.set("n", "gd", function()
          builtin.lsp_definitions(previewOpts)
        end, opts)

        vim.keymap.set("n", "gi", function()
          builtin.lsp_implementations(previewOpts)
        end, opts)

        vim.keymap.set("n", "gr", function()
          builtin.lsp_references(previewOpts)
        end, opts)

        vim.keymap.set("n", "gh", vim.lsp.buf.hover, opts)
        vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, opts)
        vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, opts)

        -- Auto format on save
        if client.supports_method("textDocument/formatting") then
          vim.api.nvim_create_autocmd("BufWritePre", {
            group = vim.api.nvim_create_augroup(
              "LspFormat." .. bufnr,
              { clear = true }),
            buffer = bufnr,
            callback = function()
              vim.lsp.buf.format({
                bufnr = bufnr,
                async = false, -- set true if you prefer async
                filter = function(format_client)
                  return format_client.name == client.name
                end,
              })
            end,
          })
        end
      end

      -- Language servers
      local lspconfig = require("lspconfig")
      lspconfig.gopls.setup({
        on_attach = on_attach_lsp,
        settings = {
          gofumt = true,
          gopls = {
            analyses = {
              unusedparams = true,
              unreachable = true,
              nilness = true,
              unusedwrite = true,
              shadow = true,
            },
            staticcheck = true,
          },
        },
      })

      lspconfig.lua_ls.setup({
        on_attach = on_attach_lsp,
        settings = {
          Lua = {
            runtime = { version = "LuaJIT" },
            diagnostics = {
              globals = { "vim" }, -- Recognize the `vim` global
            },
            workspace = {
              library = vim.api.nvim_get_runtime_file("", true),
              checkThirdParty = false,
            },
            telemetry = { enable = false },
          },
        },
      })
    end,
  }

  use {
    "hrsh7th/nvim-cmp",
    requires = {
      "hrsh7th/cmp-nvim-lsp",     -- LSP source
      "hrsh7th/cmp-buffer",       -- buffer words
      "hrsh7th/cmp-path",         -- filesystem paths
      "hrsh7th/cmp-cmdline",      -- command-line completion
      "L3MON4D3/LuaSnip",         -- snippets engine
      "saadparwaiz1/cmp_luasnip", -- LuaSnip completion source
    },
    config = function()
      local cmp = require("cmp")
      cmp.setup({
        snippet = {
          expand = function(args)
            require("luasnip").lsp_expand(args.body)
          end,
        },
        mapping = cmp.mapping.preset.insert({
          ["<C-Space>"] = cmp.mapping.complete(),
          ["<CR>"] = cmp.mapping.confirm({ select = true }),
          ["<C-n>"] = cmp.mapping.select_next_item(),
          ["<C-p>"] = cmp.mapping.select_prev_item(),
        }),
        sources = cmp.config.sources({
          { name = "nvim_lsp" },
          { name = "luasnip" },
          { name = "buffer" },
          { name = "path" },
        }),
      })
    end
  }

  -- Avante + Ollama
  use({
    "yetone/avante.nvim",
    build = "make",
    lazy = false,
    version = false,
    BUILD_FROM_SOURCE = true,
    config = function()
      require("avante_lib").load()
      require("avante").setup({
        provider = "ollama",
        providers = {
          ollama = {
            endpoint = "http://localhost:11434",
            model = "deepseek-coder:6.7b",
            api_key_name = "",
          },
        }
      })
    end,
    requires = {
      "nvim-treesitter/nvim-treesitter",
      "stevearc/dressing.nvim",
      "nvim-lua/plenary.nvim",
      "MunifTanjim/nui.nvim",
      --- The below dependencies are optional,
      "nvim-tree/nvim-web-devicons", -- or echasnovski/mini.icons
      "HakonHarnes/img-clip.nvim",
    },
  })

  -- Syntax hightlighting
  use {
    "nvim-treesitter/nvim-treesitter",
    run = ":TSUpdate", -- or `run` if still using older packer
    config = function()
      require("nvim-treesitter.configs").setup({
        ensure_installed = { "c", "lua", "vim", "vimdoc", "json", "yaml", "go", "luadoc", "markdown" },
        sync_install = false,
        auto_install = true,
        highlight = {
          enable = true,
          additional_vim_regex_highlighting = false,
        },
        indent = {
          enable = true
        },
      })
    end
  }
end)

-- Basic keymaps and options
vim.g.mapleader = " "
vim.o.number = true
vim.o.relativenumber = true
vim.o.swapfile = false
vim.o.backup = false
vim.o.undodir = os.getenv("HOME") .. "/.vim/undodir"
vim.o.undofile = true
vim.o.hlsearch = false
vim.o.incsearch = true
-- Display options
vim.o.cursorline = true
vim.o.scrolloff = 8
vim.o.signcolumn = "yes" -- always show the signcolumn on the left side
-- keymaps
vim.keymap.set("n", "}", ":BufferLineCycleNext<CR>", { noremap = true, silent = true })
vim.keymap.set("n", "{", ":BufferLineCyclePrev<CR>", { noremap = true, silent = true })

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
-- Use 2 spaces for Lua files
vim.api.nvim_create_autocmd("FileType", {
  pattern = "lua",
  callback = function()
    vim.bo.shiftwidth = 2   -- indent size
    vim.bo.tabstop = 2      -- tab width
    vim.bo.softtabstop = 2  -- how many spaces a <Tab> feels like
    vim.bo.expandtab = true -- use spaces instead of tabs
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  pattern = "go",
  callback = function()
    vim.bo.shiftwidth = 4    -- indent size
    vim.bo.tabstop = 4       -- tab width
    vim.bo.softtabstop = 4   -- how many spaces a <Tab> feels like
    vim.bo.expandtab = false -- use spaces instead of tabs
  end,
})

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

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    for _, client in pairs(vim.lsp.get_clients()) do
      client.stop()
    end
  end,
})

