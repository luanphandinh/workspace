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
          "rust_analyzer",
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

          -- Helper to check if LSP is ready; retries once on stale window
          local function with_lsp(fn)
            return function()
              if #vim.lsp.get_clients({ bufnr = 0 }) == 0 then
                vim.notify("No LSP client attached. Waiting for LSP...", vim.log.levels.WARN)
                return
              end
              local ok, err = pcall(fn)
              if not ok and type(err) == "string" and err:find("Invalid window") then
                vim.schedule(function()
                  pcall(fn)
                end)
              elseif not ok then
                vim.notify(tostring(err), vim.log.levels.ERROR)
              end
            end
          end

          vim.keymap.set("n", "gd", with_lsp(function()
            builtin.lsp_definitions(previewOpts)
          end), opts)

          vim.keymap.set("n", "gi", with_lsp(function()
            builtin.lsp_implementations(previewOpts)
          end), opts)

          vim.keymap.set("n", "gr", with_lsp(function()
            builtin.lsp_references(previewOpts)
          end), opts)

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

      -- :LspInfo was removed from nvim-lspconfig with the vim.lsp.config
      -- migration. Shim to the supported equivalent.
      vim.api.nvim_create_user_command("LspInfo", function()
        vim.cmd("checkhealth vim.lsp")
      end, { desc = "Show LSP client info (alias for :checkhealth vim.lsp)" })

      -- Use Neovim 0.11+ vim.lsp.config API
      -- Use custom gopls binary from env var, fallback to "gopls"
      local gopls_cmd = vim.env.GOPLS_PATH or "gopls"

      vim.lsp.config("gopls", {
        cmd = { gopls_cmd },
        root_markers = { "go.mod", ".git" },
        filetypes = { "go", "gomod", "gowork", "gotmpl" },
        -- Default reuse matches workspace folders; subtle root path differences spawn a 2nd gopls.
        -- Prefer one process per Nvim — gopls handles the module tree from the first workspace.
        reuse_client = function(client, config)
          if client.name ~= "gopls" or config.name ~= "gopls" or client:is_stopped() then
            return false
          end
          return true
        end,
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

      -- rust-analyzer: Rust LSP. Installed by Mason (package: rust-analyzer).
      -- Override the binary via RUST_ANALYZER_PATH if you want a system install
      -- or a nightly, same pattern as GOPLS_PATH above.
      local rust_analyzer_cmd = vim.env.RUST_ANALYZER_PATH or "rust-analyzer"

      vim.lsp.config("rust_analyzer", {
        cmd = { rust_analyzer_cmd },
        root_markers = { "Cargo.toml", "rust-project.json", ".git" },
        filetypes = { "rust" },
        settings = {
          ["rust-analyzer"] = {
            cargo = {
              allFeatures = true,
              loadOutDirsFromCheck = true,
              runBuildScripts = true,
            },
            -- rust-analyzer split the old `checkOnSave = { command = ... }`
            -- config into a boolean toggle + a separate `check` section.
            checkOnSave = true,
            check = {
              command = "clippy",
              extraArgs = { "--no-deps" },
            },
            procMacro = { enable = true },
            inlayHints = {
              bindingModeHints = { enable = false },
              chainingHints = { enable = true },
              closingBraceHints = { enable = true, minLines = 25 },
              parameterHints = { enable = true },
              typeHints = { enable = true },
            },
          },
        },
      })

      -- Enable LSP servers (auto-starts based on filetypes)
      vim.lsp.enable("gopls")
      vim.lsp.enable("rust_analyzer")
    end,
  }

  -- Autocompletion and suggestion.
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

      local function cmp_opts()
        return {
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
        }
      end

      cmp.setup(cmp_opts())

      -- Command to restart cmp (clear cmp-nvim-lsp ↔ client registrations, then re-setup).
      vim.api.nvim_create_user_command("CmpRestart", function()
        local ok_lsp, cmp_nvim_lsp = pcall(require, "cmp_nvim_lsp")
        if ok_lsp and cmp_nvim_lsp.client_source_map then
          for _, source_id in pairs(cmp_nvim_lsp.client_source_map) do
            pcall(cmp.unregister_source, source_id)
          end
          for k in pairs(cmp_nvim_lsp.client_source_map) do
            cmp_nvim_lsp.client_source_map[k] = nil
          end
          cmp_nvim_lsp.setup()
        end
        cmp.core:reset()
        cmp.setup(cmp_opts())
        print("nvim-cmp restarted")
      end, {})

      -- Keymap to restart cmp
      vim.keymap.set("n", "<leader>rs", "<cmd>CmpRestart<cr>", { desc = "Restart completion" })
    end
  }
end
