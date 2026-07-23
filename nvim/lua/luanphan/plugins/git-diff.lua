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

local function close_or_focus_existing_diffview()
  local existing_tab = find_diffview_tab()
  if not existing_tab then
    return false
  end

  if existing_tab == vim.api.nvim_get_current_tabpage() then
    vim.cmd("DiffviewClose")
  else
    vim.api.nvim_set_current_tabpage(existing_tab)
  end

  return true
end

local function toggle_diffview()
  if close_or_focus_existing_diffview() then
    return
  end

  vim.cmd("DiffviewOpen")
end

local function toggle_file_history()
  if close_or_focus_existing_diffview() then
    return
  end

  vim.cmd("DiffviewFileHistory %")
end

local function toggle_all_file_history()
  if close_or_focus_existing_diffview() then
    return
  end

  vim.cmd("DiffviewFileHistory")
end

local function normal_buffer_path()
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" or path:match("^diffview://") or vim.bo.buftype ~= "" then
    return nil
  end
  return path
end

local function absolute_diffview_path(path, view)
  if not path or path == "" then
    return nil
  end
  if vim.fn.isabsolutepath(path) == 1 then
    return path
  end

  local root = view and view.adapter and view.adapter.ctx and view.adapter.ctx.toplevel
  if root and root ~= "" then
    return root .. "/" .. path
  end
  return vim.fn.fnamemodify(path, ":p")
end

local function diffview_entry_path(entry, view)
  if not entry then
    return nil
  end
  if entry.absolute_path then
    return entry.absolute_path
  end
  if entry.right and entry.right.path then
    return absolute_diffview_path(entry.right.path, view)
  end
  if entry.left and entry.left.path then
    return absolute_diffview_path(entry.left.path, view)
  end
  return absolute_diffview_path(entry.path, view)
end

local function current_diffview_file_path(view)
  if not view then
    return nil
  end

  if type(view.infer_cur_file) == "function" then
    local ok, entry = pcall(function()
      return view:infer_cur_file(false)
    end)
    local path = ok and diffview_entry_path(entry, view) or nil
    if path then
      return path
    end
  end

  if view.panel and type(view.panel.get_item_at_cursor) == "function" then
    local ok, entry = pcall(function()
      return view.panel:get_item_at_cursor()
    end)
    local path = ok and diffview_entry_path(entry, view) or nil
    if path then
      return path
    end
  end

  local path = diffview_entry_path(view.cur_file or view.cur_entry, view)
  if path then
    return path
  end

  if view.panel and type(view.panel.ordered_file_list) == "function" then
    local ok, files = pcall(function()
      return view.panel:ordered_file_list()
    end)
    if ok and type(files) == "table" then
      for _, entry in ipairs(files) do
        path = diffview_entry_path(entry, view)
        if path then
          return path
        end
      end
    end
  end

  if view.panel and type(view.panel.list_files) == "function" then
    local ok, files = pcall(function()
      return view.panel:list_files()
    end)
    if ok and type(files) == "table" then
      for _, entry in ipairs(files) do
        path = diffview_entry_path(entry, view)
        if path then
          return path
        end
      end
    end
  end

  if view.files and type(view.files.iter) == "function" then
    local ok, iter = pcall(function()
      return view.files:iter()
    end)
    if ok then
      for _, entry in iter do
        path = diffview_entry_path(entry, view)
        if path then
          return path
        end
      end
    end
  end

  if type(view.files) == "table" then
    for _, group in pairs(view.files) do
      if type(group) == "table" then
        for _, entry in ipairs(group) do
          path = diffview_entry_path(entry, view)
          if path then
            return path
          end
        end
      end
    end
  end

  return nil
end

local function refire_current_file_runtime(buf)
  vim.schedule(function()
    if not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].buftype ~= "" then
      return
    end
    if vim.bo[buf].filetype == "" then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("filetype detect")
      end)
    end
    pcall(vim.api.nvim_exec_autocmds, "FileType", { buffer = buf, modeline = false })
  end)
end

local function same_real_path(lhs, rhs)
  if not lhs or not rhs or lhs == "" or rhs == "" then
    return false
  end
  local uv = vim.uv or vim.loop
  lhs = uv.fs_realpath(lhs) or vim.fn.fnamemodify(lhs, ":p")
  rhs = uv.fs_realpath(rhs) or vim.fn.fnamemodify(rhs, ":p")
  return lhs == rhs
end

local function current_original_line(path, view)
  local bufname = vim.api.nvim_buf_get_name(0)
  if same_real_path(bufname, path) then
    return vim.api.nvim_win_get_cursor(0)[1]
  end

  local layout = view and view.cur_layout
  if not layout or type(layout.get_main_win) ~= "function" then
    return nil
  end

  local current_win = vim.api.nvim_get_current_win()
  local in_layout = false
  for _, win in ipairs(layout.windows or {}) do
    if win.id == current_win then
      in_layout = true
      break
    end
  end
  if not in_layout then
    return nil
  end

  local ok, main_win = pcall(function()
    return layout:get_main_win()
  end)
  if not ok or not main_win or not main_win.id or not vim.api.nvim_win_is_valid(main_win.id) then
    return nil
  end
  return vim.api.nvim_win_get_cursor(main_win.id)[1]
end

local function open_original_file(path, line, lib)
  if not path then
    vim.notify("No original file found for current diff", vim.log.levels.WARN)
    return
  end

  local target_tab = lib and lib.get_prev_non_view_tabpage() or nil
  if target_tab then
    vim.api.nvim_set_current_tabpage(target_tab)
  else
    vim.cmd("tabnew")
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  if line and line > 0 then
    local last = vim.api.nvim_buf_line_count(0)
    vim.api.nvim_win_set_cursor(0, { math.min(line, last), 0 })
  end
  refire_current_file_runtime(vim.api.nvim_get_current_buf())
end

local function jump_to_original_file(view)
  local ok, lib = pcall(require, "diffview.lib")
  if ok then
    view = lib.get_current_view() or view
  end
  local path = current_diffview_file_path(view) or normal_buffer_path()
  open_original_file(path, current_original_line(path, view), ok and lib or nil)
end

local function set_diffview_jump_keymap(view, buf)
  vim.keymap.set("n", "<leader>gf", function()
    jump_to_original_file(view)
  end, { buffer = buf, desc = "Jump to original file" })
end

local function set_diffview_tab_jump_keymaps(view)
  local tab = view and view.tabpage or vim.api.nvim_get_current_tabpage()
  if not vim.api.nvim_tabpage_is_valid(tab) then
    return
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    set_diffview_jump_keymap(view, vim.api.nvim_win_get_buf(win))
  end
end

local function current_tab_has_diffview()
  local ok, active = pcall(vim.api.nvim_tabpage_get_var, vim.api.nvim_get_current_tabpage(), "diffview_active")
  return ok and active == true
end

local function each_diffview_directory(view, callback)
  local components = view.panel and view.panel.components
  if not components then
    return
  end

  for _, section in ipairs({ "conflicting", "working", "staged" }) do
    local files = components[section] and components[section].files
    if files and files.comp then
      files.comp:deep_some(function(comp)
        if comp.name == "directory" and comp.context and comp.context.path then
          callback(section .. "\0" .. comp.context.path, comp.context)
        end
        return false
      end)
    end
  end
end

local function preserve_diffview_folds(view)
  if not view.files or not vim.is_callable(view.update_files) then
    return
  end

  local function snapshot()
    local state = {}
    each_diffview_directory(view, function(key, directory)
      state[key] = directory.collapsed
    end)
    view._luanphan_fold_state = state
  end

  local function restore()
    local state = view._luanphan_fold_state or {}
    local changed = false
    each_diffview_directory(view, function(key, directory)
      if state[key] ~= nil and directory.collapsed ~= state[key] then
        directory.collapsed = state[key]
        changed = true
      end
    end)
    view._luanphan_fold_pending = false
    if changed then
      view.panel:render()
      view.panel:redraw()
    end
  end

  local update_files = view.update_files
  view.update_files = function(self, ...)
    if not self._luanphan_fold_pending then
      snapshot()
    end
    self._luanphan_fold_pending = true
    return update_files(self, ...)
  end

  view.emitter:on("tab_leave", function()
    snapshot()
    view._luanphan_fold_pending = true
  end)
  view.emitter:on("files_updated", restore)
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
  if close_or_focus_existing_diffview() then
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
  vim.keymap.set("n", "<leader>gd", with_diffview(toggle_diffview), { desc = "Diff current changes" })
  vim.keymap.set("n", "<leader>gD", with_diffview(toggle_branch_diff), { desc = "Diff branch vs base" })
  vim.keymap.set("n", "<leader>gb", with_diffview(open_current_line_commit), { desc = "Blame commit at line" })
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

            set_diffview_tab_jump_keymaps(view)
            set_diffview_jump_keymap(view, 0)
            preserve_diffview_folds(view)
            vim.schedule(function()
              set_diffview_tab_jump_keymaps(view)
            end)
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
          if current_tab_has_diffview() then
            set_diffview_jump_keymap(nil, 0)
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
      local restore_decoration_provider = require("luanphan.git_conflict_guard").install()
      local ok, err = pcall(function()
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
      end)
      restore_decoration_provider()
      if not ok then
        error(err)
      end
    end,
  },
}
