local M = {}
local api = vim.api
local views = require("luanphan.view_container")
local editors = require("luanphan.editor_window")
local workspaces = {}
local editor_appearance = {}
local tile, source
local events = api.nvim_create_augroup("LuanphanAgentEditorTile", { clear = true })

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

function M.tab(cwd)
  local state = workspaces[cwd]
  if not state then return end
  if tile and tile.state == state and api.nvim_win_is_valid(tile.win)
    and api.nvim_win_get_buf(tile.win) ~= state.buf then remember() end
  if not api.nvim_buf_is_valid(state.buf) then
    if vim.fn.filereadable(state.path) ~= 1 then return end
    state.buf = vim.fn.bufadd(state.path)
  end
  local id = "editor:" .. cwd
  return { id = id, order_key = id, bufnr = state.buf, separate_window = true,
    title = state.path == "" and "Editor" or vim.fs.basename(state.path) }
end

function M.prepare(win, anchor, cwd, opened)
  local state = workspaces[cwd]
  local changed = not tile or tile.win ~= win or tile.state ~= state or tile.buf ~= state.buf
  tile = { anchor = anchor, win = win, state = state, cwd = cwd, buf = state.buf }
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
      if workspaces[cwd] == closed.state then workspaces[cwd] = nil end
      vim.schedule(function()
        if not api.nvim_win_is_valid(anchor) then return end
        if api.nvim_win_get_config(0).relative == "" then api.nvim_set_current_win(anchor) end
        closed.state.relayout(anchor)
      end)
    end,
  })
end

function M.show(anchor, cwd, buf, view, relayout)
  local previous = workspaces[cwd]
  workspaces[cwd] = { buf = buf, path = api.nvim_buf_get_name(buf), view = view, relayout = relayout }
  relayout(anchor)
  local win = M.window(anchor)
  if not win then workspaces[cwd] = previous return false end
  vim.cmd.stopinsert()
  api.nvim_set_current_win(win)
  vim.fn.winrestview(view)
  remember()
  return true
end

function M.current()
  if tile and api.nvim_get_current_win() == tile.win then return tile.anchor, tile.cwd end
end

api.nvim_create_autocmd("QuitPre", {
  group = events,
  callback = function()
    if not M.current() then return end
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
