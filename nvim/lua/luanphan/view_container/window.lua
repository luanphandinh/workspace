local M = {}
local terminal = require("luanphan.view_container.terminal")
local closing_groups = {}
local preserve_windows = false

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
	for _, win in ipairs(windows) do
		if win ~= closing then terminal.save_view(win, vim.api.nvim_win_get_buf(win)) end
	end
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

function M.close_window(win)
	return M.close_group(M.group_anchor(win))
end

function M.with_preserved_windows(callback)
	local previous = preserve_windows
	preserve_windows = true
	local ok, result = pcall(callback)
	preserve_windows = previous
	if not ok then error(result) end
	return result
end

function M.track_directory(group, capture, hide, restore)
	local saved = {}
	vim.api.nvim_create_autocmd({ "DirChangedPre", "DirChanged" }, {
		group = group,
		callback = function(event)
			if preserve_windows then return end
			local cwd = vim.fn.getcwd()
			if event.event == "DirChangedPre" then
				saved[cwd] = capture(cwd)
				if saved[cwd] then hide() end
			elseif saved[cwd] then
				restore(cwd, saved[cwd])
			end
		end,
	})
end

function M.watch_panel(group, opts)
	local function suspended()
		return opts.suspended and opts.suspended()
	end

	local function outside(win, anchor)
		return M.group_anchor(win) ~= anchor and (vim.api.nvim_win_get_config(win).relative == ""
			or (opts.hide_on_terminal and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "terminal"))
	end

	vim.api.nvim_create_autocmd({ "WinEnter", "WinClosed" }, {
		group = group,
		callback = function(event)
			local anchor = opts.anchor()
			if not anchor then return end
			if event.event == "WinClosed" then
				local win = tonumber(event.match)
				if opts.closing and opts.closing() then return end
				local sidebar = vim.api.nvim_win_is_valid(anchor) and vim.w[anchor].luanphan_window_bar
				if win == anchor or win == sidebar or (opts.companion and opts.companion(win)) then
					opts.hide(win)
				end
				return
			end
			if not vim.api.nvim_win_is_valid(anchor) then return end
			local win = vim.api.nvim_get_current_win()
			if M.group_anchor(win) == anchor then
				if opts.enter then opts.enter(win) end
			elseif not opts.docked and not suspended() and outside(win, anchor) then
				vim.schedule(function()
					if opts.anchor() == anchor and vim.api.nvim_win_is_valid(anchor) and not suspended()
						and outside(vim.api.nvim_get_current_win(), anchor) then opts.hide() end
				end)
			end
		end,
	})
end

return M
