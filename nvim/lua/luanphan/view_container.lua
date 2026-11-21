local M = {}

local Container = {}
Container.__index = Container
local focused_tile_border = "FloatBorder:DiagnosticOk"
local closing_groups = {}

function M.group_anchor(win)
	if not vim.api.nvim_win_is_valid(win) then return win end
	return vim.w[win].luanphan_view_anchor or vim.w[win].luanphan_view_companion_anchor or win
end

function M.group_windows(anchor)
	local windows = vim.api.nvim_win_is_valid(anchor) and { anchor } or {}
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if win ~= anchor and M.group_anchor(win) == anchor then windows[#windows + 1] = win end
	end
	return windows
end

function M.close_group(anchor, closing)
	if closing_groups[anchor] then return false end
	local windows = M.group_windows(anchor)
	local closed, failure
	if vim.tbl_contains(windows, vim.api.nvim_get_current_win()) then vim.cmd.stopinsert() end
	closing_groups[anchor] = true
	-- WinClosed can be suppressed when the group is closed inside another autocmd.
	for index = #windows, 1, -1 do
		local win = windows[index]
		if win ~= closing and vim.api.nvim_win_is_valid(win) then
			local ok, err = pcall(vim.api.nvim_win_close, win, true)
			if ok then closed = true else failure = err end
		end
	end
	closing_groups[anchor] = nil
	if failure then error(failure) end
	return closed or false
end

function M.tab_label(bufnr, fallback)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return ""
	end
	local label = vim.b[bufnr].term_title
	local agent = vim.b[bufnr].luanphan_agent_name
	if agent then
		label = require("luanphan.agents.main").display_title(agent, label)
	end
	if type(label) ~= "string" or label == "" or label == vim.api.nvim_buf_get_name(bufnr) then
		label = vim.b[bufnr].luanphan_agent_saved_label or fallback or vim.b[bufnr].luanphan_view_label or ""
	end
	return (label:gsub("[%c]", " "))
end

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

function Container:context()
	return self.opts.context()
end

function Container:tabs(context)
	return self.opts.tabs(context or self:context()) or {}
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

function Container:reserve(win)
	if not win or not vim.api.nvim_win_is_valid(win) then
		return
	end
	vim.api.nvim_set_option_value("winbar", "%#TabLineFill# ", { win = win, scope = "local" })
end

function Container:render(win, context, single_tab)
	if not win or not vim.api.nvim_win_is_valid(win) then
		return
	end
	context = context or self:context()
	local tabs = single_tab and { single_tab } or self:tabs(context)

	local active = single_tab or self:active(context)
	local parts = {}
	for _, tab in ipairs(tabs) do
		local selected = active and tab.id == active.id and tab.bufnr == active.bufnr
		vim.b[tab.bufnr].luanphan_view_label = tab.label
		local label = string.format("%%{v:lua.require'luanphan.view_container'.tab_label(%d)}", tab.bufnr)
		label = selected and ("[" .. label .. "]") or label
		parts[#parts + 1] = selected and "%#TabLineSel#" or "%#TabLine#"
		parts[#parts + 1] = " " .. label .. " "
	end
	parts[#parts + 1] = "%#TabLineFill#"
	vim.api.nvim_set_option_value("winbar", table.concat(parts), { win = win, scope = "local" })
end

local function tile_geometry(geometry, count)
	local inset = geometry.border == "none" and 0 or 2
	local last = { row = geometry.row, col = geometry.col, width = geometry.width + inset, height = geometry.height + inset }
	local tiles = { last }
	for index = 2, count do
		local next_tile = vim.tbl_extend("force", {}, last)
		local vertical = index % 2 == 0
		local axis, offset = vertical and "width" or "height", vertical and "col" or "row"
		last[axis] = math.floor(next_tile[axis] / 2)
		next_tile[axis] = next_tile[axis] - last[axis]
		next_tile[offset] = next_tile[offset] + last[axis]
		tiles[index], last = next_tile, next_tile
	end
	local border_size = count > 1 and 2 or 0
	for _, tile in ipairs(tiles) do
		tile.width = tile.width - border_size
		tile.height = tile.height - border_size
		if tile.width < 1 or tile.height < 2 then return end
		tile.relative = geometry.relative
		tile.border = count > 1 and "single" or "none"
		tile.zindex = geometry.zindex
	end
	return tiles
end

local function set_tile_border_highlight(win, focused)
	if not win or not vim.api.nvim_win_is_valid(win) then return end
	local current = vim.wo[win].winhighlight
	local highlights = current:gsub(",?" .. focused_tile_border, "")
	if focused then highlights = highlights == "" and focused_tile_border or highlights .. "," .. focused_tile_border end
	if highlights ~= current then vim.wo[win].winhighlight = highlights end
end

local function reset_tiles(self, closing)
	local anchor, windows = self.tile_anchor, self.tile_windows
	if anchor ~= closing then set_tile_border_highlight(anchor, false) end
	self.tile_anchor, self.tile_windows, self.focused_tile = nil, nil, nil
	if self.tile_autocmd then
		pcall(vim.api.nvim_del_autocmd, self.tile_autocmd)
		self.tile_autocmd = nil
	end
	if anchor and vim.api.nvim_win_is_valid(anchor) then vim.w[anchor].luanphan_view_anchor = nil end
	return windows or {}
end

local function clear_tiles(self)
	for _, win in pairs(reset_tiles(self)) do
		if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
	end
end

local function highlight_focused_tile(self)
	local current = vim.api.nvim_get_current_win()
	local focused
	if next(self.tile_windows or {}) and vim.w[current].luanphan_view_anchor == self.tile_anchor then
		focused = current
	end
	local previous = self.focused_tile
	if previous ~= focused then set_tile_border_highlight(previous, false) end
	set_tile_border_highlight(focused, true)
	self.focused_tile = focused
end

local function untile(self, anchor, context)
	if self.tile_anchor ~= anchor then return end
	local active = self:active(context)
	if active then
		local focus = self.tile_windows[active.bufnr] == vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(anchor, active.bufnr)
		if focus then vim.api.nvim_set_current_win(anchor) end
	end
	clear_tiles(self)
end

local function tile(self, anchor, context, geometry)
	local tabs = self:tabs(context)
	if #tabs == 0 then return end
	local layout = tile_geometry(geometry, #tabs)
	if not layout then return end
	if self.tile_anchor ~= anchor then
		clear_tiles(self)
		self.tile_anchor = anchor
		self.tile_autocmd = vim.api.nvim_create_autocmd({ "WinEnter", "WinClosed" }, {
			callback = function(args)
				if args.event == "WinEnter" then return highlight_focused_tile(self) end
				local win = tonumber(args.match)
				if win == anchor or vim.tbl_contains(self.tile_windows or {}, win) then
					reset_tiles(self, win)
					M.close_group(anchor, win)
				end
			end,
		})
	end
	local previous, windows, panes = self.tile_windows or {}, {}, {}
	local anchor_buf = vim.api.nvim_win_get_buf(anchor)
	if not vim.iter(tabs):any(function(tab) return tab.bufnr == anchor_buf end) then
		anchor_buf = self:active(context).bufnr
		vim.api.nvim_win_set_buf(anchor, anchor_buf)
		if previous[anchor_buf] == vim.api.nvim_get_current_win() then vim.api.nvim_set_current_win(anchor) end
	end
	for index, tab in ipairs(tabs) do
		local is_anchor = tab.bufnr == anchor_buf
		local win = is_anchor and anchor or previous[tab.bufnr]
		local opened = not win or not vim.api.nvim_win_is_valid(win)
		if opened then
			win = vim.api.nvim_open_win(tab.bufnr, false, vim.tbl_extend("force", layout[index], { style = "minimal" }))
		else
			vim.api.nvim_win_set_config(win, layout[index])
		end
		vim.w[win].luanphan_view_anchor = anchor
		if not is_anchor then windows[tab.bufnr] = win end
		self:render(win, context, tab)
		panes[#panes + 1] = { win = win, tab = tab, opened = opened }
	end
	self.tile_windows = windows
	for buf, win in pairs(previous) do
		if not windows[buf] and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
	end
	highlight_focused_tile(self)
	return panes
end

function Container:display(anchor, context, geometry, style)
	self.display_style = style
	local panes = style == "tile" and tile(self, anchor, context, geometry)
	if panes then return panes end
	untile(self, anchor, context)
	vim.api.nvim_win_set_config(anchor, geometry)
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
	self.opts.activate(tabs[((index - 1 + (step or 1)) % #tabs) + 1], { view_mode = true })
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
	vim.keymap.set("n", "<Tab>", function()
		self:cycle(context)
	end, vim.tbl_extend("force", opts, { desc = self.opts.cycle_desc or "Next view" }))
	vim.keymap.set("n", "<S-Tab>", function()
		self:cycle(context, -1)
	end, vim.tbl_extend("force", opts, { desc = "Previous view" }))
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
	return setmetatable({
		opts = opts,
		active_by_context = {},
	}, Container)
end

return M
