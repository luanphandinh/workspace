---@diagnostic disable: missing-fields
local parser_install_enabled = vim.env.NVIM_INSTALL_TREESITTER == "1"
local parser_install_list = {
  "go",
  "lua",
  "c",
  "vim",
  "vimdoc",
  "json",
  "yaml",
  "luadoc",
}
local parser_installing = {}
local parser_auto_install_disabled = {
  markdown = true,
  markdown_inline = true,
  rmd = true,
}

local function install_missing_parser(ev)
  local ft = vim.bo[ev.buf].filetype
  if ft == "" or parser_auto_install_disabled[ft] then
    return
  end

  local lang = vim.treesitter.language.get_lang(ft) or ft
  if lang == "" or parser_auto_install_disabled[lang] then
    return
  end

  local ok, parsers = pcall(require, "nvim-treesitter.parsers")
  if not ok or parsers.has_parser(lang) or parser_installing[lang] then
    return
  end

  local configs = parsers.get_parser_configs()
  if not configs[lang] then
    return
  end

  parser_installing[lang] = true
  vim.schedule(function()
    vim.cmd("silent! TSInstall " .. lang)
  end)
end

return {
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
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
        auto_install = false,
        highlight = {
          enable = true,
          disable = { "markdown", "markdown_inline" },
          additional_vim_regex_highlighting = false
        },
        indent = {
          enable = true,
          disable = { "markdown" },
        },
        ensure_installed = parser_install_enabled and parser_install_list or {},
      })

      vim.api.nvim_create_autocmd("FileType", {
        callback = install_missing_parser,
      })

      vim.api.nvim_create_autocmd({ "FileType", "BufEnter", "BufWinEnter" }, {
        pattern = { "markdown", "rmd" },
        callback = function(ev)
          pcall(vim.treesitter.stop, ev.buf)
          vim.opt_local.foldmethod = "manual"
          vim.opt_local.foldexpr = ""
        end,
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
  },
}
