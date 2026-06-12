---@diagnostic disable: missing-fields
local parser_install_enabled = vim.env.NVIM_INSTALL_TREESITTER == "1"
local parser_install_dir = vim.fn.stdpath("data") .. "/site"
local parser_install_list = {
  "bash",
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
local treesitter_disabled_filetypes = {
  markdown = true,
  markdown_inline = true,
  rmd = true,
}
local treesitter_disabled_langs = {
  markdown = true,
  markdown_inline = true,
  rmd = true,
}

local bash_injections_query = [[
((comment) @injection.content
  (#set! injection.language "comment"))

((regex) @injection.content
  (#set! injection.language "regex"))
]]

local fold_manual_line_threshold = 10000

local function setup_treesitter_installer(treesitter)
  if type(treesitter.setup) == "function" then
    treesitter.setup({
      install_dir = parser_install_dir,
    })
  end
end

local function is_disabled(buf, lang)
  return treesitter_disabled_langs[lang] or treesitter_disabled_filetypes[vim.bo[buf].filetype] or false
end

local function set_manual_folds(buf)
  vim.api.nvim_buf_call(buf, function()
    vim.opt_local.foldmethod = "manual"
    vim.opt_local.foldexpr = ""
  end)
end

local function set_treesitter_folds(buf)
  if vim.api.nvim_buf_line_count(buf) > fold_manual_line_threshold then
    set_manual_folds(buf)
    return
  end

  vim.api.nvim_buf_call(buf, function()
    vim.opt_local.foldmethod = "expr"
    vim.opt_local.foldexpr = "v:lua.vim.treesitter.foldexpr()"
    vim.opt_local.foldtext = ""
    vim.opt_local.foldlevel = 99
  end)
end

local function install_missing_parser(ev)
  local ft = vim.bo[ev.buf].filetype
  if ft == "" or parser_auto_install_disabled[ft] then
    return
  end

  local lang = vim.treesitter.language.get_lang(ft) or ft
  if lang == "" or parser_auto_install_disabled[lang] then
    return
  end

  local ok, treesitter = pcall(require, "nvim-treesitter")
  if not ok or type(treesitter.get_available) ~= "function" or type(treesitter.install) ~= "function" then
    return
  end
  setup_treesitter_installer(treesitter)

  local available = treesitter.get_available()
  if not vim.tbl_contains(available, lang) or parser_installing[lang] then
    return
  end

  parser_installing[lang] = true
  treesitter.install({ lang })
end

local function install_required_parsers()
  if not parser_install_enabled then
    return
  end

  local ok, treesitter = pcall(require, "nvim-treesitter")
  if not ok or type(treesitter.install) ~= "function" then
    return
  end
  setup_treesitter_installer(treesitter)

  local task = treesitter.install(parser_install_list, { force = true, summary = true })
  if task and type(task.wait) == "function" then
    task:wait(300000)
  end
end

local function update_installed_parsers()
  local ok, treesitter = pcall(require, "nvim-treesitter")
  if not ok or type(treesitter.update) ~= "function" then
    return
  end
  setup_treesitter_installer(treesitter)

  local task = treesitter.update(nil, { summary = true })
  if task and type(task.wait) == "function" then
    task:wait(300000)
  end
end

local function start_native_treesitter(ev)
  local ft = vim.bo[ev.buf].filetype
  if ft == "" then
    return
  end

  local lang = vim.treesitter.language.get_lang(ft) or ft
  if lang == "" or is_disabled(ev.buf, lang) then
    pcall(vim.treesitter.stop, ev.buf)
    set_manual_folds(ev.buf)
    return
  end

  if vim.treesitter.highlighter.active[ev.buf] ~= nil then
    set_treesitter_folds(ev.buf)
    return
  end

  local ok = pcall(vim.treesitter.start, ev.buf, lang)
  if not ok then
    install_missing_parser(ev)
    return
  end

  set_treesitter_folds(ev.buf)
end

return {
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "main",
    build = function()
      install_required_parsers()
      update_installed_parsers()
    end,
    lazy = false,
    opts = {
      install_dir = parser_install_dir,
    },
    config = function(_, opts)
      require("nvim-treesitter").setup(opts)

      -- Keep Bash highlighting enabled, but skip nested heredoc/printf injections
      -- that can hit nil range nodes in current Neovim dev builds.
      vim.treesitter.language.register("bash", { "bash", "sh" })
      vim.treesitter.query.set("bash", "injections", bash_injections_query)
      vim.g.luanphan_bash_injection_guard = 1

      install_required_parsers()

      vim.api.nvim_create_autocmd({ "FileType", "BufEnter", "BufWinEnter" }, {
        callback = start_native_treesitter,
      })

      -- Large buffers + TS foldexpr can spin in foldUpdate on buffer switch / win_set_buf.
      -- Use manual folds so foldexpr is not recomputed.
      vim.api.nvim_create_autocmd("BufReadPost", {
        callback = function(ev)
          if vim.api.nvim_buf_line_count(ev.buf) > fold_manual_line_threshold then
            set_manual_folds(ev.buf)
          end
        end,
      })
    end
  },
}
