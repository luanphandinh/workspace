local M = {}

local unpack = table.unpack or unpack

function M.is_out_of_range_error(err)
  return tostring(err):find("Invalid 'line': out of range", 1, true) ~= nil
end

local function refresh_conflicts(bufnr)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.cmd, "GitConflictRefresh")
    end
  end)
end

function M.wrap(callback)
  return function(...)
    local results = { xpcall(callback, debug.traceback, ...) }
    local ok = table.remove(results, 1)
    if ok then
      return unpack(results)
    end

    local err = results[1]
    if M.is_out_of_range_error(err) then
      refresh_conflicts(select(3, ...))
      return false
    end
    error(err, 0)
  end
end

function M.install()
  local original = vim.api.nvim_set_decoration_provider
  local patched
  patched = function(namespace, provider)
    local info = debug.getinfo(2, "S")
    local source = info and info.source or ""
    if type(provider) == "table" and source:find("git-conflict.nvim", 1, true) then
      provider = vim.tbl_extend("force", {}, provider)
      if type(provider.on_win) == "function" then
        provider.on_win = M.wrap(provider.on_win)
      end
      if type(provider.on_buf) == "function" then
        provider.on_buf = M.wrap(provider.on_buf)
      end
    end
    return original(namespace, provider)
  end

  vim.api.nvim_set_decoration_provider = patched
  return function()
    if vim.api.nvim_set_decoration_provider == patched then
      vim.api.nvim_set_decoration_provider = original
    end
  end
end

return M
