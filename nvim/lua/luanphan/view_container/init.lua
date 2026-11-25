local window = require("luanphan.view_container.window")
local tiles = require("luanphan.view_container.tile_render")
local tabs = require("luanphan.view_container.tab_render")
local bars = require("luanphan.view_container.window_bar")
local editor = require("luanphan.view_container.editor")
local M = vim.tbl_extend("force", window, {
	tab_label = tabs.tab_label,
})
local Container = { reserve = tabs.reserve, render = tabs.render,
	refresh_tile_highlights = tiles.refresh_tile_highlights }
Container.__index = Container
local watched_layouts = setmetatable({}, { __mode = "k" })
local resize_timer

local function refresh_layouts()
	for container in pairs(watched_layouts) do
		local anchor = container.layout_anchor
		if anchor and vim.api.nvim_win_is_valid(anchor) then container.opts.relayout(anchor) end
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

local function select_item(title, items, on_select, picker_opts)
	local ok_pickers, pickers = pcall(require, "telescope.pickers")
	local ok_finders, finders = pcall(require, "telescope.finders")
	local ok_config, telescope_config = pcall(require, "telescope.config")
	local ok_actions, actions = pcall(require, "telescope.actions")
	local ok_state, action_state = pcall(require, "telescope.actions.state")
	if not (ok_pickers and ok_finders and ok_config and ok_actions and ok_state) then
		vim.ui.select(items, {
			prompt = title,
			format_item = function(item)
				return item.display or item.label or item.id
			end,
		}, on_select)
		return
	end

	pickers
		.new({}, vim.tbl_extend("force", {
			prompt_title = title,
			finder = finders.new_table({
				results = items,
				entry_maker = function(item)
					local display = item.display or item.label or item.id
					return {
						value = item,
						display = display,
						ordinal = item.ordinal or display,
					}
				end,
			}),
			sorter = telescope_config.values.generic_sorter({}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if selection and selection.value then
						vim.schedule(function()
							on_select(selection.value)
						end)
					end
				end)
				return true
			end,
		}, picker_opts or {}))
		:find()
end

function M.select(title, items, on_select, picker_opts)
	select_item(title, items, on_select, picker_opts)
end

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

function M.layout(settings, opts)
	opts = opts or {}
	local border = opts.border or (settings.display_style == "tile" and "single" or "none")
	local inset = border == "none" and 0 or 2
	local frame = {
		relative = "editor", row = 0, col = 0, width = vim.o.columns - inset,
		height = math.max(opts.min_height or 4, vim.o.lines - vim.o.cmdheight) - inset,
		border = border, zindex = opts.zindex or 40,
	}
	local body, bar
	if opts.docked then
		if opts.win and vim.api.nvim_win_is_valid(opts.win) then
			frame.row, frame.col = unpack(vim.api.nvim_win_get_position(opts.win))
			frame.width = vim.api.nvim_win_get_width(opts.win)
			frame.height = vim.api.nvim_win_get_height(opts.win)
		end
		local sidebar = math.min(42, math.max(3, math.floor(frame.width * 0.3)))
		body, bar = bars.divide(frame, settings.window_bar_style, sidebar)
	else
		body, bar = bars.float_geometry(frame, settings)
	end
	return { body = body, bar = bar, display_style = settings.display_style, bar_style = settings.window_bar_style }
end

function M.has_room(layout, count)
	return layout.display_style ~= "tile" or tiles.can_tile(layout.body, count)
end

function M.open_float(layout, buf, enter)
	return vim.api.nvim_open_win(buf, enter, vim.tbl_extend("force", layout.body, { style = "minimal" }))
end

function M.compact_picker_opts()
	return {
		layout_strategy = "center",
		layout_config = {
			width = function(_, columns) return math.min(96, math.floor(columns * 0.55)) end,
			height = function(_, _, lines) return math.min(16, math.floor(lines * 0.35)) end,
			prompt_position = "top",
		},
		results_title = false,
		previewer = false,
		sorting_strategy = "ascending",
	}
end

function Container:context()
	return self.opts.context()
end

function Container:tabs(context)
	context = context or self:context()
	local items = self.opts.tabs(context) or {}
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
	if self.layout_context ~= context or not self.visible_windows or not self.layout_anchor
		or not vim.api.nvim_win_is_valid(self.layout_anchor) then return end
	local win = self.visible_windows[buf]
	if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then return win end
end

function Container:focus_visible(context, tab, focus)
	local win = self:visible_window(context, tab.bufnr)
	if not win then return end
	self:select_tab(context, tab)
	if focus and vim.api.nvim_get_current_win() ~= win then vim.api.nvim_set_current_win(win) end
	return win
end

function Container:reflow(anchor, context, layout, active)
	if active then self:select_tab(context, active) end
	local previous = self.visible_windows or {}
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
	self.layout_anchor, self.layout_context, self.visible_windows = anchor, context, {}
	if self.opts.layout_bar then self.opts.layout_bar(anchor, layout) end
	for _, pane in ipairs(panes) do
		pane.opened = pane.opened or previous[pane.tab.bufnr] ~= pane.win
		self.visible_windows[pane.tab.bufnr] = pane.win
		self.opts.prepare_pane(pane, context, anchor)
	end
	self:refresh_tile_highlights()
	return anchor
end

function Container:active(context)
	context = context or self:context()
	local tabs = self:tabs(context)
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
	self.opts.reorder(tabs, context, win)
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

	local active = self:active(context)
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
	local choices = self.opts.choices(context) or {}
	if #choices == 0 then
		vim.notify(self.opts.empty_message or "no views available", vim.log.levels.WARN)
		return
	end
	select_item(self.opts.picker_title or "Views", choices, function(choice)
		(self.opts.create or self.opts.activate)(choice)
	end, self.opts.picker_opts)
end

function Container:create(context)
	context = context or self:context()
	if self.opts.new then
		self.opts.new(context)
		return
	end
	self:pick(context)
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
	if self.opts.create_key ~= false then
		vim.keymap.set("n", self.opts.create_key or "<leader>fn", function()
			self:create(context)
		end, vim.tbl_extend("force", opts, { desc = self.opts.new_desc or "New view" }))
	end
end

function Container:attach(win, bufnr, id, context)
	if not win or not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	context = context or self:context()
	self.active_by_context[context] = { id = id, bufnr = bufnr }
	self:bind(bufnr, context)
	if not vim.w[win].luanphan_view_anchor then self:render(win, context) end
end

function Container:forget(id, bufnr, context)
	context = context or self:context()
	if self.layout_context == context then self.visible_windows = nil end
	local active = self.active_by_context[context]
	if active and active.id == id and active.bufnr == bufnr then
		self.active_by_context[context] = nil
	end
end

function M.create(opts)
	assert(type(opts) == "table", "view container options are required")
	assert(type(opts.context) == "function", "view container context callback is required")
	assert(type(opts.tabs) == "function", "view container tabs callback is required")
	assert(type(opts.choices) == "function" or type(opts.new) == "function", "view container picker or new callback is required")
	assert(type(opts.activate) == "function", "view container activate callback is required")
	local container = setmetatable({
		opts = opts,
		active_by_context = {},
	}, Container)
	if opts.relayout then watched_layouts[container] = true end
	return container
end

return M
