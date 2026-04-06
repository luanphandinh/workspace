---@diagnostic disable: missing-fields
return function(use)
  use {
    "nvim-treesitter/nvim-treesitter",
    run = ":TSUpdate", -- or `run` if still using older packer
    config = function()
      -- Tree-sitter folds: use built-in foldexpr (|:help vim.treesitter.foldexpr()|).
      -- Legacy `nvim_treesitter#foldexpr()` can spin in foldUpdate when switching
      -- buffers (e.g. nvim_win_set_buf) on large or pathological files.
      vim.opt.foldmethod = "expr"
      vim.opt.foldexpr = "v:lua.vim.treesitter.foldexpr()"
      vim.opt.foldtext = ""
      vim.opt.foldlevel = 99

      require("nvim-treesitter.configs").setup({
        sync_install = false,
        auto_install = true,
        highlight = {
          enable = true,
          additional_vim_regex_highlighting = false
        },
        indent = {
          enable = true
        },
        ensure_installed = {
          "go",
          "lua",
          "c",
          "vim",
          "vimdoc",
          "json",
          "yaml",
          "luadoc",
          "markdown",
        },
      })

      -- Large buffers + TS foldexpr can spin in foldUpdate on buffer switch / win_set_buf.
      -- Use manual folds so foldexpr is not recomputed.
      local fold_manual_line_threshold = 10000
      vim.api.nvim_create_autocmd("BufReadPost", {
        callback = function(ev)
          if vim.api.nvim_buf_line_count(ev.buf) > fold_manual_line_threshold then
            vim.api.nvim_buf_call(ev.buf, function()
              vim.opt_local.foldmethod = "manual"
              vim.opt_local.foldexpr = ""
            end)
          end
        end,
      })
    end
  }
end
