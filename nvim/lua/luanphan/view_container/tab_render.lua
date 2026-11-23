local M = {}
local titles = {}
local window_tabs = vim.api.nvim_create_namespace("LuanphanWindowTabs")

function M.tab_label(bufnr, fallback)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return ""
	end
	local label = vim.b[bufnr].term_title
	if titles[bufnr] then label = titles[bufnr](bufnr, label) end
	if type(label) ~= "string" or label == "" or label == vim.api.nvim_buf_get_name(bufnr) then
		label = fallback or vim.b[bufnr].luanphan_view_label or ""
	end
	return (label:gsub("[%c]", " "))
end

function M.bind_title(buf, callback)
	if titles[buf] then return end
	titles[buf] = callback
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		callback = function() titles[buf] = nil end,
	})
end

function M.reserve(_, win)
	if not win or not vim.api.nvim_win_is_valid(win) then
		return
	end
	vim.api.nvim_set_option_value("winbar", "%#TabLineFill# ", { win = win, scope = "local" })
end

local function tab_text(label, selected)
	if selected then return " [" .. label .. "] ", "TabLineSel" end
	return " " .. label .. " ", "TabLine"
end

function M.format(tabs, active, title)
	local parts = {}
	for _, tab in ipairs(tabs) do
		local selected = active and tab.id == active.id and tab.bufnr == active.bufnr
		local label = tab.title and tab.title:gsub("%%", "%%%%")
		if not label then
			if title then M.bind_title(tab.bufnr, title) end
			vim.b[tab.bufnr].luanphan_view_label = tab.label
			label = string.format("%%{v:lua.require'luanphan.view_container'.tab_label(%d)}", tab.bufnr)
		end
		local text, highlight = tab_text(label, selected)
		parts[#parts + 1] = "%#" .. highlight .. "#"
		parts[#parts + 1] = text
	end
	parts[#parts + 1] = "%#TabLineFill#"
	return table.concat(parts)
end

function M.render(self, win, context, single_tab)
	if not win or not vim.api.nvim_win_is_valid(win) then return end
	context = context or self:context()
	local tabs = single_tab and { single_tab } or self:tabs(context)
	vim.wo[win].winbar = M.format(tabs, single_tab or self:active(context), self.opts.title)
end

function M.render_windows(bar)
	local labels, highlights, columns = {}, {}, {}
	local focused = vim.api.nvim_get_current_win() == bar.win
	local col = 0
	for index, row in ipairs(bar.rows) do
		local label = row.group.title
		local item = row.active or row.group.active
		if item and item.bufnr and bar.opts.status then
			local glyph = bar.opts.status(item, bar.frame)
			if glyph then label = label .. " " .. glyph end
		end
		if item and item.icon and item.icon ~= "" then label = label .. " " .. item.icon end
		local active = (focused and index == bar.selected) or (not focused and row.active)
		labels[index], highlights[index] = tab_text(label, active)
		col = col + vim.fn.strdisplaywidth(labels[index])
		columns[index] = col
	end
	bar.columns = columns
	local buf = vim.api.nvim_win_get_buf(bar.win)
	local value = table.concat(labels)
	if vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == value then return end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, 1, false, { value })
	vim.bo[buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(buf, window_tabs, 0, -1)
	local offset = 0
	for index, text in ipairs(labels) do
		vim.api.nvim_buf_set_extmark(buf, window_tabs, 0, offset, { end_col = offset + #text, hl_group = highlights[index] })
		offset = offset + #text
	end
end

return M
