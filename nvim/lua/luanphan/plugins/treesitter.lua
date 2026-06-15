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

local function is_special_buffer(buf)
  return vim.bo[buf].buftype ~= "" or vim.api.nvim_buf_get_name(buf):match("^diffview://") ~= nil
end

local function should_preserve_window_folds(buf)
  return vim.api.nvim_get_current_buf() == buf and vim.wo.diff
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

local function start_native_treesitter(ev)
  local ft = vim.bo[ev.buf].filetype
  if ft == "" then
    return
  end

  if is_special_buffer(ev.buf) then
    return
  end

  local lang = vim.treesitter.language.get_lang(ft) or ft
  local preserve_folds = should_preserve_window_folds(ev.buf)

  if lang == "" or is_disabled(ev.buf, lang) then
    pcall(vim.treesitter.stop, ev.buf)
    if not preserve_folds then
      set_manual_folds(ev.buf)
    end
    return
  end

  if vim.treesitter.highlighter.active[ev.buf] ~= nil then
    if not preserve_folds then
      set_treesitter_folds(ev.buf)
    end
    return
  end

  if not pcall(vim.treesitter.start, ev.buf, lang) then
    if not preserve_folds then
      set_manual_folds(ev.buf)
    end
    return
  end

  if not preserve_folds then
    set_treesitter_folds(ev.buf)
  end
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
      if is_special_buffer(ev.buf) or should_preserve_window_folds(ev.buf) then
        return
      end
      if vim.api.nvim_buf_line_count(ev.buf) > fold_manual_line_threshold then
        set_manual_folds(ev.buf)
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
