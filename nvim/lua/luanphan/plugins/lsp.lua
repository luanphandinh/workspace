return function(use)
  -- mason - load eagerly as it's a dependency for mason-lspconfig
  use {
    "williamboman/mason.nvim",
    config = function()
      require("mason").setup()
    end,
  }

  -- mason-lspconfig - lazy load with lspconfig
  use {
    "williamboman/mason-lspconfig.nvim",
    event = "BufReadPre",
    config = function()
      require("mason-lspconfig").setup {
        ensure_installed = {
          "gopls",
        },
        automatic_enable = false,
      }
    end,
  }

  use {
    "neovim/nvim-lspconfig",
    event = "BufReadPre",
    config = function()
      -- LSP attach handler for keymaps and formatting
      vim.api.nvim_create_autocmd("LspAttach", {
        group = vim.api.nvim_create_augroup("UserLspConfig", {}),
        callback = function(args)
          local client = vim.lsp.get_client_by_id(args.data.client_id)
          local bufnr = args.buf
          local opts = { noremap = true, silent = true, buffer = bufnr }
          local builtin = require("telescope.builtin")

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
          if client:supports_method("textDocument/formatting") then
            vim.api.nvim_create_autocmd("BufWritePre", {
              group = vim.api.nvim_create_augroup("LspFormat." .. bufnr, { clear = true }),
              buffer = bufnr,
              callback = function()
                vim.lsp.buf.format({
                  bufnr = bufnr,
                  async = false,
                  filter = function(format_client)
                    return format_client.name == client.name
                  end,
                })
              end,
            })
          end
        end,
      })

      vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = function()
          for _, client in pairs(vim.lsp.get_clients()) do
            client:stop()
          end
        end,
      })

      -- Use Neovim 0.11+ vim.lsp.config API
      -- Use custom gopls binary from env var, fallback to "gopls"
      local gopls_cmd = vim.env.GOPLS_PATH or "gopls"

      vim.lsp.config("gopls", {
        cmd = { gopls_cmd },
        root_markers = { "go.mod", ".git" },
        filetypes = { "go", "gomod", "gowork", "gotmpl" },
        settings = {
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

      -- Enable LSP servers (auto-starts based on filetypes)
      vim.lsp.enable("gopls")
    end,
  }

  -- Autocompletion and suggestion
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
        preselect = cmp.PreselectMode.Item,      -- Preselect the first item
        completion = {
          completeopt = "menu,menuone,noinsert", -- Recommended by nvim-cmp
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

      -- Command to restart cmp
      vim.api.nvim_create_user_command("CmpRestart", function()
        cmp.setup({
          snippet = {
            expand = function(args)
              require("luasnip").lsp_expand(args.body)
            end,
          },
          preselect = cmp.PreselectMode.Item,
          completion = {
            completeopt = "menu,menuone,noinsert",
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
        print("nvim-cmp restarted")
      end, {})

      -- Keymap to restart cmp
      vim.keymap.set("n", "<leader>rs", "<cmd>CmpRestart<cr>", { desc = "Restart completion" })
    end
  }
end
