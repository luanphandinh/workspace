local function cmp_opts(cmp)
  return {
    snippet = {
      expand = function(args)
        require("luasnip").lsp_expand(args.body)
      end,
    },
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

local function typescript_major(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return nil
  end

  local manifests = vim.fs.find("package.json", {
    path = vim.fs.dirname(path),
    upward = true,
    type = "file",
    limit = math.huge,
  })
  for _, manifest in ipairs(manifests) do
    local ok_lines, lines = pcall(vim.fn.readfile, manifest)
    local ok_json, package = false, nil
    if ok_lines then
      ok_json, package = pcall(vim.json.decode, table.concat(lines, "\n"))
    end
    if ok_json and type(package) == "table" then
      for _, group in ipairs({ "devDependencies", "dependencies", "peerDependencies" }) do
        local dependencies = package[group]
        local version = type(dependencies) == "table" and dependencies.typescript or nil
        local major = type(version) == "string" and tonumber(version:match("%d+")) or nil
        if major then
          return major
        end
      end
    end
  end
end

local function typescript_server(buf)
  local major = typescript_major(buf)
  return major and major >= 7 and "tsc" or "ts_ls"
end

local lsp_recover_filetypes = {
  go = "gopls",
  gomod = "gopls",
  gowork = "gopls",
  gotmpl = "gopls",
  javascript = typescript_server,
  javascriptreact = typescript_server,
  rust = "rust_analyzer",
  typescript = typescript_server,
  typescriptreact = typescript_server,
}

local lsp_recover_pending = {}

local function has_lsp_client(buf, name)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf, name = name })) do
    if not client:is_stopped() then
      return true
    end
  end
  return false
end

local function recover_lsp_for_entered_buffer(ev)
  local buf = ev.buf
  if not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].buftype ~= "" then
    return
  end
  if vim.b[buf].luanphan_jumplist_replayed then
    return
  end

  local ft = vim.bo[buf].filetype
  local server = lsp_recover_filetypes[ft]
  if type(server) == "function" then
    server = server(buf)
  end
  if not server or has_lsp_client(buf, server) or lsp_recover_pending[buf] then
    return
  end

  lsp_recover_pending[buf] = true
  vim.schedule(function()
    lsp_recover_pending[buf] = nil
    if not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].buftype ~= "" or vim.bo[buf].filetype ~= ft then
      return
    end

    local ok_lazy, lazy = pcall(require, "lazy")
    if ok_lazy then
      pcall(lazy.load, { plugins = { "nvim-lspconfig" } })
    end
    pcall(vim.api.nvim_buf_call, buf, function()
      vim.api.nvim_exec_autocmds("FileType", { buffer = buf, modeline = false })
    end)
  end)
end

local function setup_lsp_recovery_autocmd()
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "WinEnter" }, {
    group = vim.api.nvim_create_augroup("LuanphanLspRecoverEnteredBuffers", { clear = true }),
    callback = recover_lsp_for_entered_buffer,
  })
end

return {
  {
    "neovim/nvim-lspconfig",
    event = { "BufReadPre", "BufNewFile" },
    init = setup_lsp_recovery_autocmd,
    config = function()
      -- LSP attach handler for keymaps and formatting
      vim.api.nvim_create_autocmd("LspAttach", {
        group = vim.api.nvim_create_augroup("UserLspConfig", {}),
        callback = function(args)
          local client = vim.lsp.get_client_by_id(args.data.client_id)
          local bufnr = args.buf
          local opts = { silent = true, buffer = bufnr }

          local function active_client_attached()
            for _, attached in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
              if attached.initialized and not attached:is_stopped() then
                return true
              end
            end
            return false
          end

          local function window_for_buffer(preferred)
            if vim.api.nvim_win_is_valid(preferred) and vim.api.nvim_win_get_buf(preferred) == bufnr then
              return preferred
            end
            for _, win in ipairs(vim.api.nvim_list_wins()) do
              if vim.api.nvim_win_get_buf(win) == bufnr then
                return win
              end
            end
          end

          -- Preserve a navigation request while an LSP client is restarting.
          local function with_lsp(fn)
            return function()
              local source_win = vim.api.nvim_get_current_win()
              local attempts = 0

              local function run()
                attempts = attempts + 1
                if not vim.api.nvim_buf_is_valid(bufnr) then
                  return
                end

                if not active_client_attached() then
                  if attempts == 1 then
                    vim.notify("LSP is reconnecting; navigation will continue when ready", vim.log.levels.WARN)
                    recover_lsp_for_entered_buffer({ buf = bufnr })
                  end
                  if attempts < 50 then
                    vim.defer_fn(run, 100)
                  else
                    vim.notify("LSP did not reconnect in time", vim.log.levels.ERROR)
                  end
                  return
                end

                local target_win = window_for_buffer(source_win)
                if not target_win then
                  return
                end
                local ok_focus, focus_err = pcall(vim.api.nvim_set_current_win, target_win)
                if not ok_focus then
                  vim.notify(tostring(focus_err), vim.log.levels.ERROR)
                  return
                end
                local ok, err = pcall(fn, target_win)
                if not ok then
                  vim.notify(tostring(err), vim.log.levels.ERROR)
                end
              end

              run()
            end
          end

          local function telescope_lsp(method, prioritize_paths)
            return function(source_win)
              local picker_opts = {
                bufnr = bufnr,
                winnr = source_win,
                initial_mode = "normal",
                layout_strategy = "vertical",
              }
              if prioritize_paths then
                local base = require("telescope.config").values.generic_sorter(picker_opts)
                picker_opts.sorter = require("luanphan.search_priority").wrap_sorter(base)
              end
              require("telescope.builtin")[method](picker_opts)
            end
          end

          vim.keymap.set("n", "gd", with_lsp(telescope_lsp("lsp_definitions")), opts)
          vim.keymap.set("n", "gi", with_lsp(telescope_lsp("lsp_implementations", true)), opts)
          vim.keymap.set("n", "gr", with_lsp(telescope_lsp("lsp_references", true)), opts)
          vim.keymap.set("n", "gR", with_lsp(require("luanphan.incoming_call_graph").open), vim.tbl_extend(
            "force",
            opts,
            { desc = "Incoming call graph" }
          ))

          vim.keymap.set("n", "gh", vim.lsp.buf.hover, opts)
          vim.keymap.set(
            "n",
            "<leader>cd",
            vim.lsp.buf.rename,
            vim.tbl_extend("force", opts, { desc = "Change Definition" })
          )
          vim.keymap.set(
            "n",
            "<leader>ca",
            vim.lsp.buf.code_action,
            vim.tbl_extend("force", opts, { desc = "Code Action" })
          )

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

      -- Use Neovim 0.11+ vim.lsp.config API
      -- Use custom gopls binary from env var, fallback to "gopls"
      local gopls_cmd = vim.env.GOPLS_PATH or "gopls"

      vim.lsp.config("gopls", {
        cmd = { gopls_cmd },
        root_markers = { "go.mod", ".git" },
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

      -- rust-analyzer: Rust LSP. Installed by the workspace Nix profile.
      -- Override the binary via RUST_ANALYZER_PATH if you want a system install
      -- or a nightly, same pattern as GOPLS_PATH above.
      local rust_analyzer_cmd = vim.env.RUST_ANALYZER_PATH or "rust-analyzer"

      vim.lsp.config("rust_analyzer", {
        cmd = { rust_analyzer_cmd },
        root_markers = { "Cargo.toml", "rust-project.json", ".git" },
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

      for _, name in ipairs({ "tsc", "ts_ls" }) do
        local root_dir = vim.lsp.config[name].root_dir
        vim.lsp.config(name, {
          root_dir = function(bufnr, on_dir)
            if typescript_server(bufnr) == name then
              root_dir(bufnr, on_dir)
            end
          end,
        })
      end

      -- Enable LSP servers (auto-starts based on filetypes)
      vim.lsp.enable("gopls")
      vim.lsp.enable("rust_analyzer")
      vim.lsp.enable("tsc")
      vim.lsp.enable("ts_ls")
    end,
  },

  -- Autocompletion and suggestion.
  {
    "hrsh7th/nvim-cmp",
    event = "InsertEnter",
    dependencies = {
      "hrsh7th/cmp-nvim-lsp",     -- LSP source
      "hrsh7th/cmp-buffer",       -- buffer words
      "hrsh7th/cmp-path",         -- filesystem paths
      "hrsh7th/cmp-cmdline",      -- command-line completion
      "L3MON4D3/LuaSnip",         -- snippets engine
      "saadparwaiz1/cmp_luasnip", -- LuaSnip completion source
    },
    config = function()
      local cmp = require("cmp")
      cmp.setup(cmp_opts(cmp))
    end
  },
}
