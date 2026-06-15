local setup_done = false

local function start_native_treesitter(ev)
  local ft = vim.bo[ev.buf].filetype
  if ft == "" then
    return
  end

  local lang = vim.treesitter.language.get_lang(ft) or ft

  if lang == "" then
    return
  end

  if vim.treesitter.highlighter.active[ev.buf] ~= nil then
    return
  end

  pcall(vim.treesitter.start, ev.buf, lang)
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

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      start_native_treesitter({ buf = buf })
    end
  end
end

return {
  setup = setup,
}
