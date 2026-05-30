local M = {}

local function icon(enabled)
  if enabled then
    return { icon = " ", color = "green" }
  end
  return { icon = " ", color = "grey" }
end

local function gitsigns_config_enabled(key)
  local ok, config = pcall(require, "gitsigns.config")
  return ok and config.config and config.config[key] == true
end

function M.live_grep_case_sensitive()
  return icon((vim.g.luanphan_live_grep_case_sensitive or 0) ~= 0)
end

function M.live_grep_regex()
  return icon((vim.g.luanphan_live_grep_regex or 0) ~= 0)
end

function M.copilot()
  return icon(vim.fn.exists(":Copilot") == 2 and vim.g.copilot_enabled ~= 0)
end

function M.file_diff()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_get_option_value("diff", { win = win }) then
      return icon(true)
    end
  end
  return icon(false)
end

function M.terminal()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.b[buf].luanphan_toggleterm or vim.b[buf].toggle_number then
        return icon(true)
      end
    end
  end
  return icon(false)
end

function M.word_wrap()
  return icon(vim.wo.wrap)
end

function M.line_blame()
  return icon(gitsigns_config_enabled("current_line_blame"))
end

function M.word_diff()
  return icon(gitsigns_config_enabled("word_diff"))
end

function M.mapping_exists(lhs)
  local map = vim.fn.maparg(lhs, "n", false, true)
  return type(map) == "table" and not vim.tbl_isempty(map)
end

return M
