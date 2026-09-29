local M = {}

local configured = false

local function callback_upvalue(callback, target)
  if type(callback) ~= "function" then
    return nil
  end
  local info = debug.getinfo(callback, "u")
  for index = 1, info and info.nups or 0 do
    local name, value = debug.getupvalue(callback, index)
    if name == target then
      return value
    end
  end
  return nil
end

local function is_neovide_option_autocmd(autocmd)
  local option = callback_upvalue(autocmd.callback, "option_setting")
  local rpcnotify = callback_upvalue(autocmd.callback, "rpcnotify")
  if option ~= autocmd.pattern or type(rpcnotify) ~= "function" then
    return false
  end
  local ok, dumped = pcall(string.dump, rpcnotify)
  return ok and dumped:find("neovide_channel_id", 1, true) ~= nil
end

local function clear_neovide_option_autocmds()
  for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = "OptionSet" })) do
    if is_neovide_option_autocmd(autocmd) then
      pcall(vim.api.nvim_del_autocmd, autocmd.id)
    end
  end
end

local function ui_channel(args)
  local data = args and args.data or nil
  return tonumber(data and data.chan or vim.v.event.chan)
end

local function on_ui_leave(args)
  local channel = ui_channel(args)
  if not channel or channel ~= tonumber(vim.g.neovide_channel_id) then
    return
  end
  clear_neovide_option_autocmds()
  vim.g.neovide_channel_id = nil
  vim.g.neovide = false
end

local function configure()
  if configured or not vim.g.neovide then
    return
  end

  configured = true
  vim.g.neovide_scale_factor = 1.0

  local function change_scale(multiplier)
    local scale = vim.g.neovide_scale_factor * multiplier
    vim.g.neovide_scale_factor = math.max(0.5, math.min(3.0, scale))
  end

  local modes = { "n", "i", "v", "t" }
  for _, key in ipairs({ "<D-=>", "<D-+>" }) do
    vim.keymap.set(modes, key, function()
      change_scale(1.1)
    end, { desc = "Zoom in" })
  end
  vim.keymap.set(modes, "<D-->", function()
    change_scale(1 / 1.1)
  end, { desc = "Zoom out" })
  vim.keymap.set(modes, "<D-0>", function()
    vim.g.neovide_scale_factor = 1.0
  end, { desc = "Reset zoom" })

  local remote = vim.env.NEOVIDE_REMOTE_BRIDGE and require("luanphan.neovide_remote") or nil

  local function paste_clipboard()
    local ok, text = pcall(vim.fn.getreg, "+")
    if ok and text ~= "" then
      vim.api.nvim_paste(text, true, -1)
    elseif not remote or not remote.paste_clipboard_image() then
      vim.api.nvim_paste("", true, -1)
    end
  end

  vim.keymap.set({ "n", "i", "v", "c", "t" }, "<D-v>", paste_clipboard, { silent = true, desc = "Paste" })
  if remote then
    vim.keymap.set("t", "<C-v>", paste_clipboard, { silent = true, desc = "Paste" })
    vim.keymap.set("t", "<D-S-v>", function()
      if not remote.paste_clipboard_image() then
        vim.notify("Clipboard image paste is available in a remote Codex terminal", vim.log.levels.WARN)
      end
    end, { silent = true, desc = "Paste clipboard image" })
  end
end

function M.setup()
  if vim.env.NEOVIDE_REMOTE_BRIDGE then
    require("luanphan.neovide_remote").setup()
  end
  configure()
  local group = vim.api.nvim_create_augroup("LuanphanNeovideLifecycle", { clear = true })
  vim.api.nvim_create_autocmd("UIEnter", { group = group, callback = configure })
  vim.api.nvim_create_autocmd("UILeave", { group = group, callback = on_ui_leave })
end

return M
