local function find_diffview_tab()
  for _, tabid in ipairs(vim.api.nvim_list_tabpages()) do
    local wins = vim.api.nvim_tabpage_list_wins(tabid)
    for _, winid in ipairs(wins) do
      local bufname = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(winid))
      if bufname:match("^diffview://") then
        return tabid
      end
    end
  end
  return nil
end

local function toggle_diffview()
  local cur_buf = vim.api.nvim_buf_get_name(0)
  if cur_buf:match("^diffview://") then
    vim.cmd("DiffviewClose")
    return
  end

  local existing_tab = find_diffview_tab()
  if existing_tab then
    vim.api.nvim_set_current_tabpage(existing_tab)
    return
  end

  vim.cmd("DiffviewOpen")
end

local function toggle_file_history()
  local cur_buf = vim.api.nvim_buf_get_name(0)
  if cur_buf:match("^diffview://") then
    vim.cmd("DiffviewClose")
    return
  end

  local existing_tab = find_diffview_tab()
  if existing_tab then
    vim.api.nvim_set_current_tabpage(existing_tab)
    return
  end

  vim.cmd("DiffviewFileHistory %")
end

local function toggle_all_file_history()
  local cur_buf = vim.api.nvim_buf_get_name(0)
  if cur_buf:match("^diffview://") then
    vim.cmd("DiffviewClose")
    return
  end

  local existing_tab = find_diffview_tab()
  if existing_tab then
    vim.api.nvim_set_current_tabpage(existing_tab)
    return
  end

  vim.cmd("DiffviewFileHistory")
end

local function git_systemlist(args)
  local output = vim.fn.systemlist(args)
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return output
end

local function first_line(output)
  if not output or not output[1] or output[1] == "" then
    return nil
  end
  return output[1]
end

local function current_line_commit()
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" or vim.fn.filereadable(file) ~= 1 then
    vim.notify("No file under cursor for git blame", vim.log.levels.WARN)
    return nil
  end

  local dir = vim.fn.fnamemodify(file, ":h")
  local root = first_line(git_systemlist({ "git", "-C", dir, "rev-parse", "--show-toplevel" }))
  if not root then
    vim.notify("Not inside a git repository", vim.log.levels.WARN)
    return nil
  end

  local rel = first_line(git_systemlist({ "git", "-C", root, "ls-files", "--full-name", "--", file }))
  if not rel then
    vim.notify("File is not tracked by git", vim.log.levels.WARN)
    return nil
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local blame = git_systemlist({
    "git", "-C", root, "blame", "--porcelain",
    "-L", line .. "," .. line,
    "--", rel,
  })
  if not blame or not blame[1] then
    vim.notify("Could not read git blame for current line", vim.log.levels.WARN)
    return nil
  end

  local commit = blame[1]:match("^(%x+)")
  if not commit or commit:match("^0+$") then
    vim.notify("Current line is uncommitted", vim.log.levels.WARN)
    return nil
  end
  return commit, root
end

local function open_current_line_commit()
  local cur_buf = vim.api.nvim_buf_get_name(0)
  if cur_buf:match("^diffview://") then
    vim.cmd("DiffviewClose")
    return
  end

  local commit = current_line_commit()
  if not commit then return end

  local existing_tab = find_diffview_tab()
  if existing_tab then
    vim.cmd("DiffviewClose")
  end

  vim.cmd("DiffviewOpen " .. commit .. "^!")
end

local function toggle_branch_diff()
  local cur_buf = vim.api.nvim_buf_get_name(0)
  if cur_buf:match("^diffview://") then
    vim.cmd("DiffviewClose")
    return
  end

  local existing_tab = find_diffview_tab()
  if existing_tab then
    vim.api.nvim_set_current_tabpage(existing_tab)
    return
  end

  local base_branch = "main"
  local result = vim.fn.system("git rev-parse --verify main 2>/dev/null")
  if vim.v.shell_error ~= 0 then
    result = vim.fn.system("git rev-parse --verify master 2>/dev/null")
    if vim.v.shell_error == 0 then
      base_branch = "master"
    else
      result = vim.fn.system("git rev-parse --verify develop 2>/dev/null")
      if vim.v.shell_error == 0 then
        base_branch = "develop"
      end
    end
  end

  vim.cmd("DiffviewOpen " .. base_branch .. "...HEAD")
end

local function with_diffview(fn)
  return function()
    require("lazy").load({ plugins = { "diffview.nvim" } })
    fn()
  end
end

local function setup_diffview_keymaps()
  vim.keymap.set("n", "<leader>gd", with_diffview(toggle_diffview), { desc = "Git diff (current changes)" })
  vim.keymap.set("n", "<leader>gD", with_diffview(toggle_branch_diff), { desc = "Git diff branch (vs base)" })
  vim.keymap.set("n", "<leader>gb", with_diffview(open_current_line_commit), { desc = "Git blame commit at line" })
  vim.keymap.set("n", "<leader>gH", with_diffview(toggle_file_history), { desc = "File history (current)" })
  vim.keymap.set("n", "<leader>gA", with_diffview(toggle_all_file_history), { desc = "File history (all)" })
  vim.keymap.set("n", "<leader>gC", with_diffview(toggle_all_file_history), { desc = "Repo commits (all)" })
end

return {
  -- Global git diff viewer
  {
    "sindrets/diffview.nvim",
    cmd = {
      "DiffviewClose",
      "DiffviewFileHistory",
      "DiffviewFocusFiles",
      "DiffviewLog",
      "DiffviewOpen",
      "DiffviewRefresh",
      "DiffviewToggleFiles",
    },
    dependencies = "nvim-lua/plenary.nvim",
    init = setup_diffview_keymaps,
    config = function()
      require("diffview").setup({
        view = {
          default = {
            layout = "diff2_horizontal",
            winbar_info = true,
          },
        },
        file_panel = {
          win_config = {
            position = "left",
            width = 35,
          },
        },
        file_history_panel = {
          win_config = {
            position = "left",
            width = 35,
          },
        },
        hooks = {
          diff_buf_read = function(bufnr)
            vim.opt_local.wrap = false
            vim.opt_local.list = false
          end,
          view_opened = function(view)
            -- Set simple tab name
            vim.api.nvim_tabpage_set_var(0, "diffview_active", true)
            vim.cmd("filetype detect")

            -- Set keymap to jump to original file
            vim.keymap.set("n", "<leader>gf", function()
              local lib = require("diffview.lib")
              local cur_view = lib.get_current_view()
              if not cur_view then return end

              -- Get the current file entry
              local entry = cur_view.panel:get_item_at_cursor()
              if not entry then
                -- Try to get from the current file in the view
                local file = cur_view.cur_file
                if file then
                  local path = file.path
                  vim.cmd("DiffviewClose")
                  vim.cmd("edit " .. vim.fn.fnameescape(path))
                end
                return
              end

              -- Get the file path
              local path = entry.path
              if entry.right and entry.right.path then
                path = entry.right.path
              elseif entry.left and entry.left.path then
                path = entry.left.path
              end

              vim.cmd("DiffviewClose")
              vim.cmd("edit " .. vim.fn.fnameescape(path))
            end, { buffer = true, desc = "Jump to original file" })
          end,
        },
      })


      -- Close diffview with q in any diffview buffer
      vim.api.nvim_create_autocmd("BufEnter", {
        callback = function()
          local bufname = vim.api.nvim_buf_get_name(0)
          if bufname:match("diffview://") then
            vim.keymap.set("n", "q", "<cmd>DiffviewClose<cr>", { buffer = true, silent = true })
          end
        end,
      })

    end,
  },

  -- Git conflict navigation and resolution
  {
    "akinsho/git-conflict.nvim",
    version = "*",
    event = { "BufReadPre", "BufNewFile" },
    config = function()
      require("git-conflict").setup({
        -- Buffer-local only when conflict markers are present. Prefix <leader>gc + o/t/b/0 (none).
        -- Next/prev conflict keep plugin defaults [x / ]x (no leader) to avoid clashing with g* maps.
        default_mappings = {
          ours = "<leader>gco",
          theirs = "<leader>gct",
          both = "<leader>gcb",
          none = "<leader>gc0",
          prev = "[x",
          next = "]x",
        },
        default_commands = true,
        highlights = {
          incoming = "DiffAdd",
          current = "DiffText",
        },
      })
    end,
  },
}
