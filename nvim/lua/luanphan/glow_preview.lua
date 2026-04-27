-- Floating terminal preview of the current file with `glow` (https://github.com/charmbracelet/glow).
-- Shows on-disk content; save the buffer to refresh.

local M = {}

local preview_win ---@type integer?

local function is_markdown_buf()
  local ft = vim.bo.filetype
  if ft == "markdown" or ft == "rmd" then
    return true
  end
  local n = vim.api.nvim_buf_get_name(0):lower()
  return n:match("%.mdc?$") ~= nil or n:match("%.markdown$") ~= nil
end

function M.toggle()
  if preview_win and vim.api.nvim_win_is_valid(preview_win) then
    local buf = vim.api.nvim_win_get_buf(preview_win)
    vim.api.nvim_win_close(preview_win, true)
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "terminal" then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    preview_win = nil
    return
  end
  preview_win = nil

  if not is_markdown_buf() then
    vim.notify("glow preview: only for Markdown buffers", vim.log.levels.WARN)
    return
  end

  local path = vim.fn.expand("%:p")
  if path == "" then
    vim.notify("glow preview: need a saved file path", vim.log.levels.WARN)
    return
  end

  if vim.fn.executable("glow") == 0 then
    vim.notify("glow preview: install `glow` — https://github.com/charmbracelet/glow", vim.log.levels.ERROR)
    return
  end

  -- Pad around any visible nvim-tree on the left so the preview doesn't
  -- overlap it; ratio applies to the remaining width. Skipped if the tree
  -- is the only non-float window (no editing buffer to protect).
  local pad = 0
  do
    local tree_w = 0
    local has_editor = false
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(win)
      local bt = vim.bo[b].buftype
      local ft = vim.bo[b].filetype
      if ft == "NvimTree" then
        tree_w = math.max(tree_w, vim.api.nvim_win_get_width(win))
      elseif bt == "" then
        has_editor = true
      end
    end
    if tree_w > 0 and has_editor then
      pad = tree_w + 1 -- +1 = split separator
    end
  end

  -- Geometry mirrors `terminal_agent.lua`'s "full" mode: full height (no
  -- top/bottom padding), 80% width centered inside `cols - pad` so the
  -- float scales/shifts when nvim-tree is open without overlapping it.
  local bufnr = vim.api.nvim_create_buf(false, true)
  local lines_avail = math.max(1, vim.o.lines - vim.o.cmdheight)
  local avail_cols = vim.o.columns - pad
  local w = math.max(40, math.min(math.floor(avail_cols * 0.80), avail_cols - 2))
  local h = math.max(10, lines_avail - 2)  -- full height; -2 for borders
  local row = 0
  local col = math.max(pad, pad + math.floor((avail_cols - w) / 2))

  local win_opts = {
    relative = "editor",
    width = w,
    height = h,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
  }
  if vim.fn.has("nvim-0.9") == 1 then
    win_opts.title = " glow "
    win_opts.title_pos = "center"
  end

  preview_win = vim.api.nvim_open_win(bufnr, true, win_opts)

  -- Embedded terminals often get wrong $COLUMNS; glow then word-wraps too narrow.
  -- Match glow's wrap width and env to this float so lines use the full window width.
  local cols = vim.api.nvim_win_get_width(0)
  local rows = vim.api.nvim_win_get_height(0)
  local env = vim.tbl_extend("force", {}, vim.fn.environ())
  env.COLUMNS = tostring(cols)
  env.LINES = tostring(rows)

  vim.fn.termopen({
    "glow",
    "-w",
    tostring(cols),
    path,
  }, {
    cwd = vim.fn.fnamemodify(path, ":h"),
    env = env,
  })

  -- glow renders the doc and exits — the PTY is then dead. The repo's
  -- TermOpen autocmd (terminal.lua) put us in terminal mode while the float
  -- was opening, and any key sent to a dead PTY causes nvim to wipe the
  -- defunct terminal buffer. Drop to normal mode the moment glow exits so
  -- j/k/g-g/G/etc. work as scroll commands and the preview persists until
  -- the user closes it explicitly.
  vim.api.nvim_create_autocmd("TermClose", {
    buffer = bufnr,
    once = true,
    callback = function()
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          local cur = vim.api.nvim_get_current_buf()
          if cur == bufnr then
            pcall(vim.cmd, "stopinsert")
          end
        end
      end)
    end,
  })

  -- Close keymaps: <leader>fp toggles, q is a fast normal-mode close.
  local close_opts = { buffer = bufnr, silent = true, desc = "Close glow preview" }
  vim.keymap.set("n", "<leader>fp", function() M.toggle() end, close_opts)
  vim.keymap.set("n", "q", function() M.toggle() end, close_opts)
  vim.keymap.set(
    "t",
    "<leader>fp",
    "<C-\\><C-n><cmd>lua require('luanphan.glow_preview').toggle()<cr>",
    close_opts
  )
end

return M
