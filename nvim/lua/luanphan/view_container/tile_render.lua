local M = {}
local window = require("luanphan.view_container.window")
local inactive_tile_color = "LuanphanInactiveTile"
local input_border_color = "LuanphanTileInputBorder"
local thin_border = { "┌", "─", "┐", "│", "┘", "─", "└", "│" }
local heavy_border = { "┏", "━", "┓", "┃", "┛", "━", "┗", "┃" }
local ascii_border = { "+", "=", "+", "|", "+", "=", "+", "|" }

local function focused_border()
	local chars = vim.o.ambiwidth == "double" and ascii_border or heavy_border
	local highlight = vim.api.nvim_get_mode().mode == "t" and input_border_color or "DiagnosticOk"
	return vim.tbl_map(function(char) return { char, highlight } end, chars)
end

local function blend_color(color, target, amount)
	local result = 0
	for shift = 16, 0, -8 do
		local from = bit.band(bit.rshift(color, shift), 255)
		local to = bit.band(bit.rshift(target, shift), 255)
		result = result * 256 + math.floor(from + (to - from) * amount + 0.5)
	end
	return result
end

local function update_tile_colors()
	local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
	if normal.bg then
		if normal.fg then normal.fg = blend_color(normal.fg, normal.bg, 0.32) end
		normal.bg = blend_color(normal.bg, 0, 0.45)
	end
	vim.api.nvim_set_hl(0, inactive_tile_color, normal)
	vim.api.nvim_set_hl(0, input_border_color, { fg = 0xfe8019, ctermfg = 208 })
end

update_tile_colors()
vim.api.nvim_create_autocmd("ColorScheme", {
	group = vim.api.nvim_create_augroup("LuanphanTileColors", { clear = true }),
	callback = update_tile_colors,
})

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

function M.can_tile(geometry, count)
	return tile_geometry(geometry, count) ~= nil
end

local function set_tile_highlights(win, border, inactive)
	if not win or not vim.api.nvim_win_is_valid(win) then return end
	if border and not vim.deep_equal(vim.api.nvim_win_get_config(win).border, border) then
		vim.api.nvim_win_set_config(win, { border = border == thin_border and "single" or border })
	end
	local current = vim.wo[win].winhighlight
	local highlights = current:gsub(":" .. inactive_tile_color .. "%f[,%z]", ":Normal")
	if inactive then highlights = highlights:gsub(":Normal%f[,%z]", ":" .. inactive_tile_color) end
	if highlights ~= current then vim.wo[win].winhighlight = highlights end
end

local function reset_tiles(self, closing)
	local anchor, windows = self.tile_anchor, self.tile_windows
	if anchor ~= closing then set_tile_highlights(anchor, nil, false) end
	self.tile_anchor, self.tile_windows = nil, nil
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

function M.refresh_tile_highlights(self)
	local current = vim.api.nvim_get_current_win()
	local windows = self.tile_windows or {}
	local multiple = next(windows) ~= nil
	local border = multiple and focused_border()
	local anchor_border = multiple and (current == self.tile_anchor and border or thin_border)
	set_tile_highlights(self.tile_anchor, anchor_border, multiple and current ~= self.tile_anchor)
	for _, win in pairs(windows) do
		set_tile_highlights(win, win == current and border or thin_border, win ~= current)
	end
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
		self.tile_autocmd = vim.api.nvim_create_autocmd({ "WinEnter", "WinClosed", "ModeChanged" }, {
			callback = function(args)
				if args.event ~= "WinClosed" then return self:refresh_tile_highlights() end
				local win = tonumber(args.match)
				if win == anchor or vim.tbl_contains(self.tile_windows or {}, win) then
					reset_tiles(self, win)
					window.close_group(anchor, win)
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
	return panes
end

function M.display(self, anchor, context, geometry, style)
	self.display_style = style
	local panes = style == "tile" and tile(self, anchor, context, geometry)
	if panes then return panes end
	untile(self, anchor, context)
	vim.api.nvim_win_set_config(anchor, geometry)
end

return M
