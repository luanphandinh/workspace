local M = {}
local api = vim.api
local views = require("luanphan.view_container.window")
local editors = require("luanphan.editor_window")
local editors_by_context = setmetatable({}, { __mode = "k" })
local panels = setmetatable({}, { __mode = "k" })
local editor_appearance = {}
local tile, source
local events = api.nvim_create_augroup("LuanphanViewEditor", { clear = true })

function M.register(container, anchor, context)
  panels[container] = { container = container, anchor = anchor, context = context, key = container.opts.editor.key(context) }
end

local function panel_for(win)
  local anchor = views.group_anchor(win)
  for _, panel in pairs(panels) do
    if panel.anchor == anchor and api.nvim_win_is_valid(anchor) then return panel end
  end
end

local function remember()
  if not tile or not tile.win or not api.nvim_win_is_valid(tile.win) then return end
  tile.state.buf = api.nvim_win_get_buf(tile.win)
  tile.state.path = api.nvim_buf_get_name(tile.state.buf)
  tile.state.view = api.nvim_win_call(tile.win, vim.fn.winsaveview)
end

local function detach()
  if not tile then return end
  remember()
  local win = tile.win
  tile = nil
  if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
end

api.nvim_create_autocmd("WinLeave", {
  group = events,
  callback = function()
    if tile and api.nvim_get_current_win() == tile.win then remember() end
  end,
})
api.nvim_create_autocmd("DirChangedPre", { group = events, callback = detach })

function M.remember_source(win)
  if editors.is_editor(win) then
    source = win
    editor_appearance[api.nvim_win_get_tabpage(win)] = editors.appearance(win)
  end
end

function M.source(anchor)
  if editors.is_editor(source) and api.nvim_win_get_tabpage(source) == api.nvim_win_get_tabpage(anchor) then
    return source
  end
  return editors.find(anchor)
end

function M.main_window()
  if tile and api.nvim_win_is_valid(tile.anchor) then return M.source(tile.anchor) end
end

local function main_appearance(anchor, main)
  local tabpage = api.nvim_win_get_tabpage(anchor)
  if main then editor_appearance[tabpage] = editors.appearance(main) end
  return editor_appearance[tabpage] or editors.appearance()
end

local function tile_appearance(anchor)
  local options = vim.tbl_extend("force", {}, main_appearance(anchor, M.source(anchor)))
  local highlights, background = {}, "Normal"
  for _, entry in ipairs(vim.split(options.winhighlight, ",", { plain = true, trimempty = true })) do
    local name, group = entry:match("^([^:]+):(.*)$")
    if name == "Normal" and group ~= "" then background = group end
    if name ~= "NormalFloat" then highlights[#highlights + 1] = entry end
  end
  highlights[#highlights + 1] = "NormalFloat:" .. background
  options.winhighlight = table.concat(highlights, ",")
  options.winbar = nil
  return options
end

function M.window(anchor)
  if tile and tile.anchor == anchor and tile.win and api.nvim_win_is_valid(tile.win) then return tile.win end
end

function M.focus(anchor)
  local win = M.window(anchor)
  if not win or api.nvim_win_get_config(win).hide then return false end
  api.nvim_set_current_win(win)
  return true
end

function M.tab(key)
  local state = editors_by_context[key]
  if not state then return end
  if tile and tile.state == state and api.nvim_win_is_valid(tile.win)
    and api.nvim_win_get_buf(tile.win) ~= state.buf then remember() end
  if not api.nvim_buf_is_valid(state.buf) then
    if vim.fn.filereadable(state.path) ~= 1 then return end
    state.buf = vim.fn.bufadd(state.path)
  end
  return { id = "editor:" .. tostring(key), bufnr = state.buf, separate_window = true,
    title = state.path == "" and "Editor" or vim.fs.basename(state.path) }
end

function M.add_tab(key, tabs)
  local tab = M.tab(key)
  if tab then
    tabs = vim.list_slice(tabs)
    table.insert(tabs, math.min(editors_by_context[key].position or #tabs + 1, #tabs + 1), tab)
  end
  return tabs
end

function M.remove_tab(key, tabs)
  for index, tab in ipairs(tabs) do
    if tab.separate_window then
      editors_by_context[key].position = index
      table.remove(tabs, index)
      return
    end
  end
end

function M.prepare(container, win, opened)
  local panel = panels[container]
  local anchor, key = panel.anchor, panel.key
  local state = editors_by_context[key]
  local changed = not tile or tile.win ~= win or tile.state ~= state or tile.buf ~= state.buf
  tile = { anchor = anchor, win = win, state = state, panel = panel, buf = state.buf }
  if opened or changed then editors.apply_appearance(win, tile_appearance(anchor)) end
  if not opened then return end
  api.nvim_win_call(win, function() vim.fn.winrestview(state.view) end)
  api.nvim_create_autocmd("WinClosed", {
    group = events, pattern = tostring(win), once = true,
    callback = function()
      if not tile or tile.win ~= win then return end
      local closed = tile
      remember()
      tile = nil
      if not closed.dismissing then return end
      if editors_by_context[key] == closed.state then editors_by_context[key] = nil end
      vim.schedule(function()
        if not api.nvim_win_is_valid(anchor) then return end
        if api.nvim_win_get_config(0).relative == "" then api.nvim_set_current_win(anchor) end
        container.opts.editor.refresh(anchor)
      end)
    end,
  })
end

local function show(panel, buf, view)
  local previous = editors_by_context[panel.key]
  editors_by_context[panel.key] = { buf = buf, path = api.nvim_buf_get_name(buf), view = view,
    position = previous and previous.position }
  panel.container.opts.editor.refresh(panel.anchor)
  local win = M.window(panel.anchor)
  if not win then editors_by_context[panel.key] = previous return false end
  vim.cmd.stopinsert()
  api.nvim_set_current_win(win)
  vim.fn.winrestview(view)
  remember()
  return true
end

function M.open_reference(win, path, line, column)
  local panel = panel_for(win)
  if not panel then return false end
  return show(panel, vim.fn.bufadd(path), { lnum = tonumber(line) or 1, col = math.max(0, (tonumber(column) or 1) - 1) })
end

function M.open_current()
  local panel = panel_for(api.nvim_get_current_win())
  if not panel then return end
  local main = M.source(panel.anchor)
  if not main then return end
  show(panel, api.nvim_win_get_buf(main), api.nvim_win_call(main, vim.fn.winsaveview))
end

function M.bind(buf)
  vim.keymap.set("n", "<leader>ne", M.open_current,
    { buffer = buf, silent = true, nowait = true, desc = "Open editor tile" })
end

function M.handle_key(action, value)
  if not tile or api.nvim_get_current_win() ~= tile.win then return false end
  local win = tile.win
  vim.schedule(function()
    if not tile or tile.win ~= win or api.nvim_get_current_win() ~= win then return end
    local container, context = tile.panel.container, tile.panel.context
    if action == "navigate" then
      container.opts.editor.navigate(win, value)
    elseif action == "move" then
      container:move_tile(value, context)
    else
      container:cycle(context, value)
    end
  end)
  return true
end

api.nvim_create_autocmd("QuitPre", {
  group = events,
  callback = function()
    if not tile or api.nvim_get_current_win() ~= tile.win then return end
    local closing = tile
    closing.dismissing = true
    vim.schedule(function() closing.dismissing = nil end)
  end,
})

function M.open_in_main()
  local win = api.nvim_get_current_win()
  if not tile or tile.win ~= win then return end
  local anchor = tile.anchor
  local main = M.source(anchor)
  local options = main_appearance(anchor, main)
  remember()
  local state = tile.state
  if main then
    api.nvim_win_set_buf(main, state.buf)
  else
    main = api.nvim_open_win(state.buf, false, { split = "right", win = -1 })
  end
  views.close_group(anchor)
  api.nvim_set_current_win(main)
  editors.apply_appearance(main, options)
  vim.fn.winrestview(state.view)
end

return M
