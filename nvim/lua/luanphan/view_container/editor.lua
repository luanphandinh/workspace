local M = {}
local api = vim.api
local views = require("luanphan.view_container.window")
local editors = require("luanphan.editor_window")
local editors_by_context = setmetatable({}, { __mode = "k" })
local panels = setmetatable({}, { __mode = "k" })
local sidebar_selection = setmetatable({}, { __mode = "k" })
local editor_appearance = {}
local tile, source
local events = api.nvim_create_augroup("LuanphanViewEditor", { clear = true })

function M.register(container, anchor, context)
  panels[container] = { container = container, anchor = anchor, context = context, key = container.opts.editor.key(context) }
end

local function panel_for(win)
  if not win then return end
  local anchor = views.group_anchor(win)
  for _, panel in pairs(panels) do
    if panel.anchor == anchor and api.nvim_win_is_valid(anchor) then return panel end
  end
end

local function remember()
  if not tile or not tile.win or not api.nvim_win_is_valid(tile.win) then return end
  local buf = api.nvim_win_get_buf(tile.win)
  if vim.bo[buf].buftype ~= "" then return end
  tile.state.buf = buf
  tile.state.path = api.nvim_buf_get_name(buf)
  tile.state.view = api.nvim_win_call(tile.win, vim.fn.winsaveview)
end

local function restorable_state(key)
  local state = editors_by_context[key]
  if not state then return end
  if tile and tile.state == state and api.nvim_win_is_valid(tile.win)
    and api.nvim_win_get_buf(tile.win) ~= state.buf then remember() end
  if api.nvim_buf_is_valid(state.buf) or (state.path ~= "" and vim.fn.filereadable(state.path) == 1) then
    return state
  end
  editors_by_context[key] = nil
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

function M.sidebar_items(anchor, groups)
  local panel = panel_for(anchor)
  local by_group = {}
  if not panel then return by_group end
  local win = M.window(anchor)
  if win then
    local anchor_buf = api.nvim_win_get_buf(anchor)
    for _, group in ipairs(groups) do
      local host = vim.iter(group.items):find(function(item) return item.bufnr == anchor_buf end)
      if host then
        tile.state.sidebar = { group = group.id, host = host.id }
        break
      end
    end
  end
  for key, state in pairs(editors_by_context) do
    if state.container == panel.container and state.sidebar and restorable_state(key) then
      local buf = win and tile.state == state and api.nvim_win_get_buf(win) or nil
      local path = buf and api.nvim_buf_get_name(buf) or state.path
      local group = state.sidebar.group
      by_group[group] = by_group[group] or {}
      table.insert(by_group[group], {
        key = key, id = "editor:" .. tostring(key), bufnr = buf, separate_window = true,
        label = path == "" and "Editor" or "Editor · " .. vim.fs.basename(path),
        position = state.position, host = state.sidebar.host,
      })
    end
  end
  return by_group
end

function M.select_sidebar(anchor, key, activate)
  local panel = panel_for(anchor)
  if not panel then return false end
  sidebar_selection[panel.container] = nil
  if key == nil then return end
  if panel.key == key then return M.focus(anchor) end
  sidebar_selection[panel.container] = key
  local selected = activate()
  if not selected then sidebar_selection[panel.container] = nil end
  return selected
end

function M.tab(key)
  local state = restorable_state(key)
  if not state then return end
  if not api.nvim_buf_is_valid(state.buf) then
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
  if sidebar_selection[container] == key then
    vim.schedule(function()
      if sidebar_selection[container] ~= key then return end
      sidebar_selection[container] = nil
      if panels[container].key == key and views.group_anchor(api.nvim_get_current_win()) == anchor then M.focus(anchor) end
    end)
  end
  if opened or changed then editors.apply_appearance(win, tile_appearance(anchor)) end
  if not opened then return end
  api.nvim_win_call(win, function()
    -- New floats inherit the opening window's jump list.
    vim.cmd.clearjumps()
    vim.fn.winrestview(state.view)
  end)
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
        container:relayout(anchor)
      end)
    end,
  })
end

local function show(panel, buf, view)
  local previous = editors_by_context[panel.key]
  editors_by_context[panel.key] = { buf = buf, path = api.nvim_buf_get_name(buf), view = view,
    container = panel.container, position = previous and previous.position, sidebar = previous and previous.sidebar }
  panel.container:relayout(panel.anchor)
  local win = M.window(panel.anchor)
  if not win then editors_by_context[panel.key] = previous return false end
  vim.cmd.stopinsert()
  api.nvim_set_current_win(win)
  vim.fn.winrestview(view)
  remember()
  return true
end

local function reopen(panel, source_buf)
  local container = panel.container
  if panel_for(api.nvim_get_current_win()) or not api.nvim_buf_is_valid(source_buf) then return end
  local context = container:context()
  if context ~= nil and context ~= panel.context then return end
  local source_tab = vim.iter(container.opts.tabs(panel.context) or {}):find(function(tab)
    return tab.bufnr == source_buf
  end)
  if not source_tab then return end
  container.opts.activate(source_tab, { view_mode = true })
  local restored = panels[container]
  if restored.key == panel.key and api.nvim_win_is_valid(restored.anchor) then return restored end
end

function M.open_reference(win, path, line, column)
  local panel = panel_for(win)
  if not panel then return end
  local source_buf = api.nvim_win_get_buf(win)
  local buf = vim.fn.bufadd(path)
  if not api.nvim_buf_is_loaded(buf) then
    -- Let file-read and filetype callbacks finish before changing tile windows.
    vim.fn.bufload(buf)
  end
  local current = panels[panel.container]
  if api.nvim_buf_is_loaded(buf) and current.key == panel.key then
    local view = { lnum = tonumber(line) or 1, col = math.max(0, (tonumber(column) or 1) - 1) }
    if api.nvim_win_is_valid(current.anchor) and show(current, buf, view) then return true end
    current = panels[panel.container]
    if current.key == panel.key and not api.nvim_win_is_valid(current.anchor) then
      local restored = reopen(panel, source_buf)
      if restored and show(restored, buf, view) then return true end
    end
  end
  vim.notify("Could not open the reference in an editor tile", vim.log.levels.WARN)
  return false
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
      container:navigate(win, value)
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
