local M = {}

local Container = {}
Container.__index = Container

local function escape_statusline(value)
	return tostring(value):gsub("%%", "%%%%")
end

local function select_item(title, items, on_select)
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
		.new({}, {
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
		})
		:find()
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

function Container:render(win, context)
	if not win or not vim.api.nvim_win_is_valid(win) then
		return
	end
	context = context or self:context()
	local tabs = self:tabs(context)
	if #tabs < 2 then
		vim.api.nvim_set_option_value("winbar", "", { win = win, scope = "local" })
		return
	end

	local active = self:active(context)
	local parts = {}
	for _, tab in ipairs(tabs) do
		local selected = active and tab.id == active.id and tab.bufnr == active.bufnr
		local label = selected and ("[" .. tab.label .. "]") or tab.label
		parts[#parts + 1] = selected and "%#TabLineSel#" or "%#TabLine#"
		parts[#parts + 1] = " " .. escape_statusline(label) .. " "
	end
	parts[#parts + 1] = "%#TabLineFill#"
	vim.api.nvim_set_option_value("winbar", table.concat(parts), { win = win, scope = "local" })
end

function Container:cycle(context)
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
	self.opts.activate(tabs[(index % #tabs) + 1], { view_mode = true })
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
	end)
end

function Container:create(context)
	context = context or self:context()
	if self.opts.new then
		self.opts.new(context)
		return
	end
	self:pick(context)
end

function Container:attach(win, bufnr, id, context)
	if not win or not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	context = context or self:context()
	self.active_by_context[context] = { id = id, bufnr = bufnr }

	local opts = { buffer = bufnr, noremap = true, silent = true, nowait = true }
	vim.keymap.set("n", "<Tab>", function()
		self:cycle(context)
	end, vim.tbl_extend("force", opts, { desc = self.opts.cycle_desc or "Next view" }))
	vim.keymap.set("n", "<leader>fn", function()
		self:create(context)
	end, vim.tbl_extend("force", opts, { desc = self.opts.new_desc or "New view" }))

	self:render(win, context)
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
