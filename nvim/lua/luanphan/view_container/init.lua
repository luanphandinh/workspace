local window = require("luanphan.view_container.window")
local tiles = require("luanphan.view_container.tile_render")
local tabs = require("luanphan.view_container.tab_render")
local bars = require("luanphan.view_container.window_bar")
local editor = require("luanphan.view_container.editor")
local terminal = require("luanphan.view_container.terminal")
local pane_order = require("luanphan.view_container.pane_order")
local pane_state = require("luanphan.view_container.pane_state")
local picker = require("luanphan.view_container.picker")
local geometry = require("luanphan.view_container.geometry")
local M = vim.tbl_extend("force", window, {
	tab_label = tabs.tab_label, workspace_groups = bars.workspace_groups,
	select = picker.select, compact_picker_opts = picker.compact_opts, layout = geometry.layout,
})
local Container = { reserve = tabs.reserve, render = tabs.render,
	refresh_tile_highlights = tiles.refresh_tile_highlights }
Container.__index = Container
local watched_layouts = setmetatable({}, { __mode = "k" })
local resize_timer
local floating_panel

function M.show_panel(panel)
	if floating_panel and floating_panel ~= panel then floating_panel.hide() end
	floating_panel = not panel.docked and panel or nil
	if not panel.docked then editor.remember_source(vim.api.nvim_get_current_win()) end
end

function M.toggle_panel(panel, open)
	local source = not panel.docked and editor.main_window()
	if not panel.hide() then return (open or panel.open)() end
	if source and vim.api.nvim_win_is_valid(source) then vim.api.nvim_set_current_win(source) end
end

local function refresh_layouts()
	for container in pairs(watched_layouts) do
		container:relayout()
	end
end

local layout_events = vim.api.nvim_create_augroup("LuanphanViewLayout", { clear = true })
vim.api.nvim_create_autocmd("VimResized", {
	group = layout_events,
	callback = function()
		if resize_timer then vim.fn.timer_stop(resize_timer) end
		resize_timer = vim.fn.timer_start(250, function()
			resize_timer = nil
			refresh_layouts()
		end)
	end,
})
vim.api.nvim_create_autocmd("BufWritePost", {
	group = layout_events,
	callback = function(event)
		local path = vim.uv.fs_realpath(require("luanphan.global_settings").config_path())
		if path and path == vim.uv.fs_realpath(vim.api.nvim_buf_get_name(event.buf)) then refresh_layouts() end
	end,
})


function M.focus_neighbor(win, direction, activate)
	local neighbor = window.tile_neighbor(win, direction)
	if not neighbor then return false end
	local anchor = window.group_anchor(win)
	if neighbor == editor.window(anchor) then
		editor.focus(anchor)
	else
		activate(neighbor)
	end
	return true
end

function M.navigate(win, direction, activate, bar, cycle_tabs)
	if M.focus_neighbor(win, direction, activate) then return true end
	if cycle_tabs and cycle_tabs(direction) then return true end
	return bar:focus_towards(direction)
end

function M.replacement_tab(items, buf)
	for index, item in ipairs(items) do
		if item.bufnr == buf then return items[index > 1 and index - 1 or index + 1] end
	end
end


function M.has_room(layout, count)
	return layout.display_style ~= "tile" or tiles.can_tile(layout.body, count)
end


function Container:context()
	return self.opts.context()
end

function Container:panes(context, kind)
	return self.opts.panes.backend.panes(kind, context)
end

function Container:recent_pane(context, kind, prefer_visible, accept)
	local source = self.opts.panes
	local selected, last_used, tied = nil, -1, false
	for _, pane in ipairs(self:panes(context, kind)) do
		local buf = pane.bufnr
		if not accept or accept(source.kind(buf)) then
			if prefer_visible and vim.fn.bufwinid(buf) ~= -1 then return buf end
			local used = source.last_used(buf)
			if used > last_used then
				selected, last_used, tied = buf, used, false
			elseif used == last_used then
				tied = true
			end
		end
	end
	-- When reopening across providers, older panes with equal ranks follow display order.
	if tied and not kind then
		for _, tab in ipairs(self:pane_tabs(context)) do
			if tab.last_used == last_used and (not accept or accept(tab.kind)) then return tab.bufnr end
		end
	end
	return selected
end

function Container:live_tabs(context, closing_buf)
	local source = self.opts.panes
	local grouped = {}
	local function add(buf, path)
		local kind = source.kind(buf)
		grouped[kind] = grouped[kind] or {}
		local paths = grouped[kind]
		paths[path] = paths[path] or {}
		local buffers = paths[path]
		buffers[#buffers + 1] = buf
		return buffers
	end
	for _, pane in ipairs(self:panes(context)) do add(pane.bufnr, pane.data.cwd) end
	-- Keep the closing pane in position while choosing its replacement.
	if closing_buf and not source.backend.running(closing_buf) then table.sort(add(closing_buf, context)) end

	local items = {}
	for _, kind in ipairs(source.kinds) do
		for path, buffers in pairs(grouped[kind] or {}) do
			if context or vim.fn.isdirectory(path) == 1 then
				for index, buf in ipairs(buffers) do
					items[#items + 1] = {
						id = buf, bufnr = buf, kind = kind, path = path, last_used = source.last_used(buf),
						label = #buffers > 1 and (kind .. " " .. index) or kind,
					}
				end
			end
		end
	end
	return items
end

function Container:pane_tabs(context, closing_buf)
	if self.opts.tabs then return self.opts.tabs(context, closing_buf) or {} end
	local items = self:live_tabs(context, closing_buf)
	if self.display_style == "tile" then table.sort(items, function(a, b) return a.bufnr < b.bufnr end) end
	pane_order.sort(items)
	return items
end

function Container:tabs(context)
	context = context or self:context()
	local items = self:pane_tabs(context)
	if self.opts.editor then return editor.add_tab(self.opts.editor.key(context), items) end
	return items
end

function Container:display(anchor, context, layout)
	local geometry, style = layout.body, layout.display_style
	local options = self.opts.editor
	if not options then return tiles.display(self, anchor, context, geometry, style) end
	editor.register(self, anchor, context)
	local visible
	if style ~= "tile" and editor.tab(options.key(context)) then
		local active = options.active and options.active(context) or vim.api.nvim_win_get_buf(anchor)
		visible = vim.tbl_filter(function(tab) return tab.separate_window or tab.bufnr == active end, self:tabs(context))
	end
	local panes = tiles.display(self, anchor, context, geometry, style, visible)
	if not panes or not vim.api.nvim_win_is_valid(anchor) then return end
	for index, pane in ipairs(panes) do
		if pane.tab.separate_window then
			if vim.api.nvim_win_is_valid(pane.win) then editor.prepare(self, pane.win, pane.opened) end
			table.remove(panes, index)
			break
		end
	end
	return panes
end

function Container:select_tab(context, tab)
	self.active_by_context[context] = { id = tab.id, bufnr = tab.bufnr }
end

function Container:visible_window(context, buf)
	if self.layout_context ~= context or not self.visible_panes or not self:anchor() then return end
	local pane = self.visible_panes[buf]
	local win = pane and pane.win
	if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then return win end
end

function Container:anchor()
	local anchor = self.layout_anchor
	return anchor and vim.api.nvim_win_is_valid(anchor) and anchor or nil
end

-- True while a layout is open, even if its anchor window is being closed.
function Container:is_open()
	return self.layout_anchor ~= nil
end

function Container:current_context()
	return self.layout_context
end

function Container:is_tile(win)
	return vim.tbl_contains(self.tile_windows or {}, win)
end

-- Forget the remembered active tab of every context.
function Container:clear_selection()
	self.active_by_context = {}
end

function Container:content_window()
	local anchor = self:anchor()
	if not anchor then return end
	local current = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_win_get_buf(current)
	return self:visible_window(self.layout_context, buf) == current and current or anchor
end

function Container:hide(closing)
	local anchor = self.layout_anchor
	if not anchor then return false end
	self.layout_anchor, self.layout_context, self.visible_panes = nil, nil, nil
	local bar = self.opts.bar()
	if bar then bar:reset() end
	return window.close_group(anchor, closing)
end

function Container:use_anchor(win)
	if self.layout_anchor ~= win then
		self:hide()
		self.layout_anchor = win
	end
	return win
end

function Container:open_float(layout, buf, enter)
	return self:use_anchor(terminal.open_window(buf, enter, layout.body))
end

function Container:watch(group, opts)
	window.watch_panel(group, vim.tbl_extend("force", {
		anchor = function() return self.layout_anchor end,
		hide = function(win) return self:hide(win) end,
		suspended = function() return self.switching end,
		enter = function(win)
			local context, buf = self.layout_context, vim.api.nvim_win_get_buf(win)
			local active = self.active_by_context[context]
			if self:visible_window(context, buf) ~= win or (active and active.bufnr == buf) then return end
			vim.schedule(function()
				local selected = self.active_by_context[context]
				if vim.api.nvim_get_current_win() == win and self:visible_window(context, buf) == win
					and (not selected or selected.bufnr ~= buf) then
					local pane = self.visible_panes[buf]
					self.opts.activate(pane.tab, { view_mode = vim.api.nvim_get_mode().mode ~= "t" })
				end
			end)
		end,
	}, opts or {}))
end

function Container:with_panel_windows(callback)
	local anchor = self:anchor()
	if not anchor then return callback() end
	vim.cmd.stopinsert()
	local previous = self.switching
	self.switching = true
	local ok, result = pcall(callback, window.group_windows(anchor))
	self.switching = previous
	if not ok then error(result) end
	return result
end

function Container:reuse(target, opts)
	local win = self:content_window()
	if not win or vim.api.nvim_win_get_buf(win) == target then return opts end
	return vim.tbl_extend("force", opts or {}, { reuse_win = self.layout_anchor })
end

function Container:create_bar(opts)
	local source = self.opts.panes
	if source then
		opts.order_panes = true
		opts.load_order = source.backend.load_window_order
		opts.save_order = source.backend.save_window_order
	end
	opts.container = self
	return bars.create(opts)
end

function Container:layout_sidebar(anchor, layout)
	self.opts.bar():layout(anchor, layout)
end

function Container:bind_title(bufnr)
	if self.opts.title then tabs.bind_title(bufnr, self.opts.title) end
end

function Container:invalidate_sidebar()
	self.opts.bar():invalidate()
end

function Container:focus_tile(context, tab, focus)
	local win = self:visible_window(context, tab.bufnr)
	if not win then return end
	self:select_tab(context, tab)
	if focus and vim.api.nvim_get_current_win() ~= win then vim.api.nvim_set_current_win(win) end
	local bar = self.opts.bar()
	bar.history.record(tab.bufnr)
	bar:follow(tab.bufnr, true)
	return win
end

function Container:present_tile(context, tab, win)
	if self:visible_window(context, tab.bufnr) == win then return self:focus_tile(context, tab, false) end
	self:select_tab(context, tab)
	self.opts.bar().history.record(tab.bufnr)
	return self:relayout(win, context)
end

function Container:relayout(win, context)
	local anchor = win and window.group_anchor(win) or self:anchor()
	if not anchor or not vim.api.nvim_win_is_valid(anchor) or terminal.is_closing_tile(anchor) then return end
	if self.opts.relayout then return self.opts.relayout(anchor) end
	return self:reflow(anchor, context or self.layout_context or self:context(), self.opts.layout())
end

function Container:refresh()
	self:invalidate_sidebar()
	return self:relayout()
end

function Container:navigate(win, direction)
	if self.opts.navigate then return self.opts.navigate(win, direction) end
	return M.navigate(win, direction, function(neighbor)
		local pane = self.visible_panes and self.visible_panes[vim.api.nvim_win_get_buf(neighbor)]
		if pane then self.opts.activate(pane.tab, { view_mode = true }) end
	end, self.opts.bar())
end

-- `new_keys(sidebar)` returns the panel's { lhs, callback, desc } mappings for creating panes;
-- they share one <leader>n which-key menu.
local function bind_new_keys(buf, keys)
	local base = { buffer = buf, silent = true, nowait = true }
	for _, key in ipairs(keys) do
		vim.keymap.set("n", key[1], key[2], vim.tbl_extend("force", base, { desc = key[3] }))
	end
	if vim.b[buf].luanphan_view_new_menu then return end
	local ok, which_key = pcall(require, "which-key")
	if ok then
		which_key.add({ { "<leader>n", group = "New", buffer = buf } })
		vim.b[buf].luanphan_view_new_menu = true
	end
end

function Container:bind_panel_buffer(buf, sidebar)
	if self.opts.editor then editor.bind(buf) end
	if self.opts.new_keys then bind_new_keys(buf, self.opts.new_keys(sidebar)) end
	if self.opts.bind_actions then self.opts.bind_actions(buf, sidebar) end
end

function Container:bind_terminal(buf, context, bar)
	(bar or self.opts.bar()):attach_terminal(buf)
	self:bind(buf, context)
	self:bind_tile_moves(buf, context)
	terminal.bind_navigation(buf, function(win, direction) self:navigate(win, direction) end)
	self:bind_panel_buffer(buf, false)
end

function Container:reflow(anchor, context, layout, active, opts)
	if active then self:select_tab(context, active) end
	local previous = self.visible_panes or {}
	for buf, pane in pairs(previous) do terminal.save_view(pane.win, buf) end
	local panes = self:display(anchor, context, layout)
	if not vim.api.nvim_win_is_valid(anchor) then return end
	if not panes then
		if active and vim.api.nvim_win_get_buf(anchor) ~= active.bufnr then
			self:reserve(anchor)
			vim.api.nvim_win_set_buf(anchor, active.bufnr)
		end
		local buf = vim.api.nvim_win_get_buf(anchor)
		local tab = active or vim.iter(self:tabs(context)):find(function(item) return item.bufnr == buf end)
		if tab then self:select_tab(context, tab) end
		self:render(anchor, context)
		panes = tab and { { win = anchor, tab = tab } } or {}
	end
	self:use_anchor(anchor)
	self.layout_context, self.visible_panes = context, {}
	self:layout_sidebar(anchor, layout)
	for _, pane in ipairs(panes) do
		local old = previous[pane.tab.bufnr]
		pane.opened = pane.opened or not old or old.win ~= pane.win
		self.visible_panes[pane.tab.bufnr] = pane
		if self.opts.prepare_pane then
			self.opts.prepare_pane(pane, context, anchor)
		elseif pane.opened then
			terminal.configure_window(pane.win, self.opts.highlights)
		end
		terminal.show_view(pane.win, pane.tab.bufnr, pane.opened)
	end
	local bar = self.opts.bar()
	if opts and active then
		local focus = opts.focus or (opts.restore_focus and M.group_anchor(vim.api.nvim_get_current_win()) ~= anchor)
		local win = focus and self:visible_window(context, active.bufnr)
		if win and vim.api.nvim_get_current_win() ~= win then vim.api.nvim_set_current_win(win) end
		if opts.record then bar.history.record(active.bufnr) end
	end
	self:refresh_tile_highlights()
	bar:redraw(vim.api.nvim_get_current_win() == bar.win)
	return anchor
end

function Container:active(context, tabs)
	context = context or self:context()
	tabs = tabs or self:tabs(context)
	local current_buf = vim.api.nvim_get_current_buf()
	for _, tab in ipairs(tabs) do
		if tab.bufnr == current_buf then
			return tab
		end
	end

	local active = self.active_by_context[context]
	if active then
		for _, tab in ipairs(tabs) do
			if tab.id == active.id and tab.bufnr == active.bufnr then
				return tab
			end
		end
	end
	return tabs[1]
end

function Container:open_tile(context, spawn, keep_order)
	local focused = self.tile_anchor
		and self:visible_window(context, vim.api.nvim_get_current_buf()) == vim.api.nvim_get_current_win()
	if keep_order or not (focused or self.opts.insert_after_active) then return spawn() end

	local tabs = vim.list_slice(self:pane_tabs(context))
	local active = self:active(context, tabs)
	local index = vim.iter(tabs):enumerate():find(function(_, tab) return tab == active end)
	if not index then return spawn() end
	return spawn(function(tab)
		table.insert(tabs, index + 1, tab)
		return tabs
	end)
end

function Container:save_pane_order(items)
	pane_order.assign(items, function(item, position)
		if item.bufnr then
			if not vim.api.nvim_buf_is_valid(item.bufnr) then return end
			pane_order.persist(item.bufnr, position)
		end
		if self.opts.snapshot then pane_state.defer(item, self.opts.snapshot, position) end
	end, pane_order.get)
end

function Container:reorder_panes(items, context, win)
	if self.opts.reorder then return self.opts.reorder(items, context, win) end
	self:save_pane_order(items)
	return self:refresh()
end

function Container:move_tile(direction, context)
	local win = vim.api.nvim_get_current_win()
	if not self.tile_anchor or M.group_anchor(win) ~= self.tile_anchor then return end
	local neighbor = M.tile_neighbor(win, direction)
	if not neighbor then return end

	context = context or self:context()
	local tabs = vim.list_slice(self:tabs(context))
	local current_buf = vim.api.nvim_win_get_buf(win)
	local neighbor_buf = vim.api.nvim_win_get_buf(neighbor)
	local source, target
	for index, tab in ipairs(tabs) do
		if tab.bufnr == current_buf then source = index end
		if tab.bufnr == neighbor_buf then target = index end
	end
	if not source or not target then return end

	table.insert(tabs, target, table.remove(tabs, source))
	if self.opts.editor then editor.remove_tab(self.opts.editor.key(context), tabs) end
	self:reorder_panes(tabs, context, win)
end

function Container:bind_tile_moves(bufnr, context)
	for direction, label in pairs({ h = "left", j = "down", k = "up", l = "right" }) do
		vim.keymap.set("n", "<C-S-" .. direction .. ">", function() self:move_tile(direction, context) end,
			{ buffer = bufnr, silent = true, desc = "Move tile " .. label })
	end
end

function Container:cycle(context, step)
	context = context or self:context()
	local tabs = self:tabs(context)
	if #tabs < 2 then
		return
	end

	local active = self:active(context, tabs)
	local index = 1
	for current, tab in ipairs(tabs) do
		if active and tab.id == active.id and tab.bufnr == active.bufnr then
			index = current
			break
		end
	end
	local next_tab = tabs[((index - 1 + (step or 1)) % #tabs) + 1]
	if next_tab.separate_window then
		editor.focus(self.tile_anchor)
	else
		self.opts.activate(next_tab, { view_mode = true })
	end
end

function Container:navigate_tabs(direction, count, only_unsplit)
	if count < 2 or (direction ~= "h" and direction ~= "l") then return false end
	if only_unsplit then
		if self.tile_anchor then return false end
	elseif self.display_style ~= "tabs" then
		return false
	end
	self:cycle(nil, direction == "h" and -1 or 1)
	return true
end

function Container:pick(context)
	context = context or self:context()
	local choices = self.opts.choices and self.opts.choices(context) or {}
	if #choices == 0 then
		vim.notify(self.opts.empty_message or "no views available", vim.log.levels.WARN)
		return
	end
	picker.select(self.opts.picker_title or "Views", choices, function(choice)
		(self.opts.create or self.opts.activate)(choice)
	end, self.opts.picker_opts)
end

function Container:bind(bufnr, context)
	local opts = { buffer = bufnr, silent = true, nowait = true }
	for _, binding in ipairs({ { "<Tab>", 1 }, { "<S-Tab>", -1 } }) do
		local key, step = unpack(binding)
		local desc = step == 1 and (self.opts.cycle_desc or "Next view") or "Previous view"
		vim.keymap.set("n", key, function()
			self:cycle(context, step)
		end, vim.tbl_extend("force", opts, { desc = desc }))
	end
end

function Container:remove_tab(bufnr, context, on_close)
	local win = vim.fn.bufwinid(bufnr)
	local reflow = win ~= -1 and win ~= vim.api.nvim_get_current_win() and vim.w[win].luanphan_view_anchor
	if win == -1 and self.layout_context == context then reflow = self.layout_anchor end
	if self.layout_context == context then self.visible_panes = nil end
	local active = self.active_by_context[context]
	if active and active.bufnr == bufnr then self.active_by_context[context] = nil end
	vim.schedule(function()
		if on_close then on_close() end
		local bar = self.opts.bar()
		bar:invalidate()
		if reflow and vim.api.nvim_win_is_valid(reflow) then
			self:relayout(reflow, context)
		else
			bar:redraw()
		end
	end)
end

function Container:replacement(context, buf)
	return M.replacement_tab(self:pane_tabs(context, buf), buf)
end

function Container:focus_replacement(tab)
	if tab and self.opts.activate(tab, { view_mode = true }) then return end
	local bar = self.opts.bar()
	if not bar:jump(1, 1) then bar:jump(-1, 1) end
end

function M.create(opts)
	assert(type(opts) == "table", "view container options are required")
	assert(type(opts.context) == "function", "view container context callback is required")
	assert(type(opts.tabs) == "function" or opts.panes, "view container pane source is required")
	assert(type(opts.activate) == "function", "view container activate callback is required")
	local container = setmetatable({
		opts = opts,
		active_by_context = {},
	}, Container)
	if opts.relayout or opts.layout then watched_layouts[container] = true end
	return container
end

return M
