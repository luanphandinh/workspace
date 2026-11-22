local window = require("luanphan.view_container.window")
local tiles = require("luanphan.view_container.tile_render")
local tabs = require("luanphan.view_container.tab_render")
local M = vim.tbl_extend("force", window, {
	tab_label = tabs.tab_label,
	can_tile = tiles.can_tile,
})
local Container = { reserve = tabs.reserve, render = tabs.render, display = tiles.display,
	refresh_tile_highlights = tiles.refresh_tile_highlights }
Container.__index = Container

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

function M.compact_picker_opts()
	return {
		layout_strategy = "center",
		layout_config = {
			width = function(_, columns) return math.min(96, math.floor(columns * 0.55)) end,
			height = function(_, _, lines) return math.min(16, math.floor(lines * 0.35)) end,
			prompt_position = "top",
		},
		previewer = false,
		sorting_strategy = "ascending",
	}
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
