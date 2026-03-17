return function(use)
  -- mason, automatically install lsp deps
  use {
    "williamboman/mason.nvim",
    config = function()
      require("mason").setup()
    end,
  }

  use {
    "williamboman/mason-lspconfig.nvim",
    after = "mason.nvim",
    config = function()
      require("mason-lspconfig").setup {
        ensure_installed = {
          "gopls",
          "lua_ls",
        }, -- auto-install these LSPs
        automatic_enable = false,
      }
    end,
  }

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

      vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = function()
          for _, client in pairs(vim.lsp.get_clients()) do
            client.stop()
          end
        end,
      })

      -- Use Neovim 0.11+ vim.lsp.config API (replaces deprecated lspconfig setup)
      vim.lsp.config.gopls = {
        cmd = { "gopls" },
        root_markers = { "go.mod", ".git" },
        filetypes = { "go", "gomod", "gowork", "gotmpl" },
        on_attach = on_attach_lsp,
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
      }

      vim.lsp.config.lua_ls = {
        cmd = { "lua-language-server" },
        root_markers = { ".luarc.json", ".luarc.jsonc", ".git" },
        filetypes = { "lua" },
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
      }

      -- Auto-start LSP servers when opening relevant file types
      vim.api.nvim_create_autocmd("FileType", {
        pattern = { "go", "gomod", "gowork", "gotmpl" },
        callback = function()
          vim.lsp.start({ name = "gopls" })
        end,
      })

      vim.api.nvim_create_autocmd("FileType", {
        pattern = "lua",
        callback = function()
          vim.lsp.start({ name = "lua_ls" })
        end,
      })
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
    end
  }
end
