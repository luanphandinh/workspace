local M = {}

-- State for gitignore visibility
local show_gitignore = false

function M.set_gitignore_visible(visible)
  if show_gitignore == visible then
    return
  end
  show_gitignore = visible

  -- Snapshot the tree window's width BEFORE toggling. nvim-tree's
  -- toggle/reload path resizes to the default `view.width` in some
  -- configurations; restoring the user's actual width afterwards is
  -- the cheap + version-robust fix.
  local tree_win, saved_width = nil, nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == "NvimTree" then
      tree_win = win
      saved_width = vim.api.nvim_win_get_width(win)
      break
    end
  end

  -- Flip nvim-tree's git_ignored filter in place. Calling `setup()` here
  -- would merge with defaults and reset `view.width` (and any other
  -- non-default option), so use the targeted toggle API instead.
  local ok_api, tree_api = pcall(require, "nvim-tree.api")
  if ok_api then
    tree_api.tree.toggle_gitignore_filter()
    tree_api.tree.reload()
  end

  -- Restore width on the next tick so any deferred nvim-tree redraw
  -- finishes first.
  if tree_win and saved_width then
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(tree_win) then
        pcall(vim.api.nvim_win_set_width, tree_win, saved_width)
      end
    end)
  end

  -- Update telescope to include/exclude gitignored files
  local ignore_dot_git = { "%.git[/\\]" }
  require("telescope").setup({
    defaults = {
      file_ignore_patterns = ignore_dot_git,
      vimgrep_arguments = show_gitignore
          and { "rg", "--color=never", "--no-heading", "--with-filename", "--line-number", "--column", "--smart-case", "--no-ignore" }
          or { "rg", "--color=never", "--no-heading", "--with-filename", "--line-number", "--column", "--smart-case" },
    },
    pickers = {
      find_files = {
        file_ignore_patterns = ignore_dot_git,
        find_command = show_gitignore
            and { "rg", "--files", "--follow", "--no-ignore" }
            or { "rg", "--files", "--follow" },
      },
    },
  })
end

function M.toggle_gitignore()
  M.set_gitignore_visible(not show_gitignore)
  print("Gitignore visibility: " .. (show_gitignore and "ON" or "OFF"))
end

return M
