local M = {}
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

function M.tile_neighbor(win, direction)
	local anchor = vim.w[win].luanphan_view_anchor
	if not anchor then return end
	local horizontal = direction == "h" or direction == "l"
	local backward = direction == "h" or direction == "k"
	local function edges(id)
		local cfg = vim.api.nvim_win_get_config(id)
		local border = cfg.border and cfg.border ~= "none" and 2 or 0
		local right, bottom = cfg.col + cfg.width + border, cfg.row + cfg.height + border
		if horizontal then return cfg.col, right, cfg.row, bottom end
		return cfg.row, bottom, cfg.col, right
	end
	local first, last, cross_first, cross_last = edges(win)
	local neighbor, nearest
	for _, candidate in ipairs(M.group_windows(anchor)) do
		if candidate ~= win and vim.w[candidate].luanphan_view_anchor == anchor then
			local start, finish, cross_start, cross_finish = edges(candidate)
			local touches = (backward and finish == first) or (not backward and start == last)
			if touches and cross_start < cross_last and cross_finish > cross_first then
				local distance = math.max(0, cross_start - cross_first)
				if not nearest or distance < nearest then neighbor, nearest = candidate, distance end
			end
		end
	end
	return neighbor
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

return M
