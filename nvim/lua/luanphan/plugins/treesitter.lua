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

local fold_manual_line_threshold = 10000
local setup_done = false

local function is_disabled(buf, lang)
  return treesitter_disabled_langs[lang] or treesitter_disabled_filetypes[vim.bo[buf].filetype] or false
end

local function window_folds_configured(buf)
  local configured = vim.w.luanphan_treesitter_folds_configured
  return type(configured) == "table" and configured[buf] == true
end

local function mark_window_folds_configured(buf)
  local configured = vim.w.luanphan_treesitter_folds_configured
  if type(configured) ~= "table" then
    configured = {}
  end
  configured[buf] = true
  vim.w.luanphan_treesitter_folds_configured = configured
end

local function should_configure_window_folds(buf)
  return vim.api.nvim_get_current_buf() == buf and not vim.wo.diff and not window_folds_configured(buf)
end

local function set_manual_folds(buf)
  vim.api.nvim_buf_call(buf, function()
    vim.opt_local.foldmethod = "manual"
    vim.opt_local.foldexpr = ""
  end)
end

local function configure_manual_folds(buf)
  if not should_configure_window_folds(buf) then
    return
  end

  set_manual_folds(buf)
  mark_window_folds_configured(buf)
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

local function configure_treesitter_folds(buf)
  if not should_configure_window_folds(buf) then
    return
  end

  set_treesitter_folds(buf)
  mark_window_folds_configured(buf)
end

local function start_native_treesitter(ev)
  local ft = vim.bo[ev.buf].filetype
  if ft == "" then
    return
  end

  local lang = vim.treesitter.language.get_lang(ft) or ft

  if lang == "" or is_disabled(ev.buf, lang) then
    pcall(vim.treesitter.stop, ev.buf)
    configure_manual_folds(ev.buf)
    return
  end

  if vim.treesitter.highlighter.active[ev.buf] ~= nil then
    configure_treesitter_folds(ev.buf)
    return
  end

  if not pcall(vim.treesitter.start, ev.buf, lang) then
    configure_manual_folds(ev.buf)
    return
  end

  configure_treesitter_folds(ev.buf)
end

local function setup()
  if setup_done then
    return
  end
  setup_done = true

  vim.treesitter.language.register("bash", { "bash", "sh" })

  vim.api.nvim_create_autocmd({ "FileType", "BufEnter", "BufWinEnter" }, {
    group = vim.api.nvim_create_augroup("luanphan_native_treesitter", { clear = true }),
    callback = start_native_treesitter,
  })

  vim.api.nvim_create_autocmd("BufReadPost", {
    group = vim.api.nvim_create_augroup("luanphan_native_treesitter_large_buffers", { clear = true }),
    callback = function(ev)
      if not should_configure_window_folds(ev.buf) then
        return
      end
      if vim.api.nvim_buf_line_count(ev.buf) > fold_manual_line_threshold then
        set_manual_folds(ev.buf)
        mark_window_folds_configured(ev.buf)
      end
    end,
  })

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      start_native_treesitter({ buf = buf })
    end
  end
end

return {
  setup = setup,
}
