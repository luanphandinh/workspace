local M = {}

local configured = false

local function configure()
  if configured or not vim.g.neovide then
    return
  end

  configured = true
  vim.g.neovide_scale_factor = 1.0
  vim.g.neovide_scroll_animation_length = 0.1
  vim.opt.mousescroll = "ver:6,hor:6"

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
  vim.api.nvim_create_autocmd("UIEnter", { callback = configure })
end

return M
