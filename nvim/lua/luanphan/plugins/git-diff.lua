local recent_paths = require("luanphan.recent_paths")

local pending_workspace_diff = nil
local switch_workspace_diff
local close_workspace_diff

local function find_diffview_tab()
  local ok, lib = pcall(require, "diffview.lib")
  if ok then
    for _, view in ipairs(lib.views or {}) do
      if view.tabpage and vim.api.nvim_tabpage_is_valid(view.tabpage) then
        local state = view._luanphan_workspace_diff
        local active = state and state.views and state.views[state.active] or nil
        if active and active.tabpage and vim.api.nvim_tabpage_is_valid(active.tabpage) then
          return active.tabpage
        end
        return view.tabpage
      end
    end
  end

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
    local ok, lib = pcall(require, "diffview.lib")
    local view = ok and lib.get_current_view() or nil
    if view and view._luanphan_workspace_diff and close_workspace_diff then
      close_workspace_diff(view)
    else
      vim.cmd("DiffviewClose")
    end
  else
    vim.api.nvim_set_current_tabpage(existing_tab)
  end

  return true
end

local function open_diffview(repo, revision)
  local command = "DiffviewOpen"
  if revision and revision ~= "" then
    command = command .. " " .. revision
  end
  if repo and repo ~= "" then
    command = command .. " -C" .. vim.fn.fnameescape(repo)
  end
  vim.cmd(command)
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
    pcall(vim.api.nvim_buf_call, buf, function()
      vim.api.nvim_exec_autocmds("FileType", { buffer = buf, modeline = false })
    end)
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

local function diffview_repository()
  local ok, lib = pcall(require, "diffview.lib")
  local view = ok and lib.get_current_view() or nil
  if not view then
    return nil, nil
  end
  local repo = view and view.adapter and view.adapter.ctx and view.adapter.ctx.toplevel
  if type(repo) ~= "string" or repo == "" then
    return nil, view
  end
  return repo, view
end

local function git_error(label, code, stdout, stderr)
  local lines = {}
  vim.list_extend(lines, stderr or {})
  vim.list_extend(lines, stdout or {})
  local detail = vim.trim(table.concat(lines, "\n"))
  local message = string.format("%s failed (exit %d)", label, code)
  if detail ~= "" then
    message = message .. ": " .. detail
  end
  vim.notify(message, vim.log.levels.ERROR)
end

local function run_git(repo, args, callback)
  local command = { "git", "-C", repo }
  vim.list_extend(command, args)
  local stdout = {}
  local stderr = {}
  local job = vim.fn.jobstart(command, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      stdout = data or {}
    end,
    on_stderr = function(_, data)
      stderr = data or {}
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        callback(code, stdout, stderr)
      end)
    end,
  })
  if job <= 0 then
    vim.notify("Could not start git command", vim.log.levels.ERROR)
    return false
  end
  return true
end

local operation_in_progress = {}

local function commit_diffview()
  local repo, view = diffview_repository()
  if not repo then
    vim.notify("Commit is only available inside an active Diffview", vim.log.levels.WARN)
    return
  end
  if operation_in_progress[repo] then
    vim.notify("Git operation already in progress for " .. vim.fn.fnamemodify(repo, ":t"), vim.log.levels.WARN)
    return
  end

  vim.ui.input({ prompt = "Commit message: " }, function(message)
    message = message and vim.trim(message) or ""
    if message == "" then
      return
    end

    operation_in_progress[repo] = "commit"
    vim.notify("Committing " .. vim.fn.fnamemodify(repo, ":t") .. "...")
    local started = run_git(repo, { "commit", "-m", message }, function(code, stdout, stderr)
      operation_in_progress[repo] = nil
      if code ~= 0 then
        git_error("Commit", code, stdout, stderr)
        return
      end

      if view and vim.is_callable(view.update_files) then
        pcall(view.update_files, view)
      end
      vim.notify("Committed: " .. message)
    end)
    if not started then
      operation_in_progress[repo] = nil
    end
  end)
end

local function push_diffview()
  local repo = diffview_repository()
  if not repo then
    vim.notify("Push is only available inside an active Diffview", vim.log.levels.WARN)
    return
  end
  if operation_in_progress[repo] then
    vim.notify("Git operation already in progress for " .. vim.fn.fnamemodify(repo, ":t"), vim.log.levels.WARN)
    return
  end

  operation_in_progress[repo] = "push"
  vim.notify("Pushing " .. vim.fn.fnamemodify(repo, ":t") .. " to origin HEAD...")
  local started = run_git(repo, { "push", "origin", "HEAD" }, function(code, stdout, stderr)
    operation_in_progress[repo] = nil
    if code ~= 0 then
      git_error("Push", code, stdout, stderr)
      return
    end
    vim.notify("Push successful")
  end)
  if not started then
    operation_in_progress[repo] = nil
  end
end

local function set_diffview_keymaps(view, buf)
  vim.keymap.set("n", "<leader>gf", function()
    jump_to_original_file(view)
  end, { buffer = buf, desc = "Jump to original file" })
  vim.keymap.set("n", "<leader>gc", function()
    commit_diffview()
  end, { buffer = buf, desc = "Commit staged changes" })
  vim.keymap.set("n", "<leader>gp", function()
    push_diffview()
  end, { buffer = buf, desc = "Push origin HEAD" })
  vim.keymap.set("n", "[r", function()
    switch_workspace_diff(view, -1, false, true)
  end, { buffer = buf, desc = "Previous diff repository" })
  vim.keymap.set("n", "]r", function()
    switch_workspace_diff(view, 1, false, true)
  end, { buffer = buf, desc = "Next diff repository" })
end

local function set_diffview_tab_keymaps(view)
  local tab = view and view.tabpage or vim.api.nvim_get_current_tabpage()
  if not vim.api.nvim_tabpage_is_valid(tab) then
    return
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    set_diffview_keymaps(view, vim.api.nvim_win_get_buf(win))
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

local function git_root(path)
  return first_line(git_systemlist({ "git", "-C", path, "rev-parse", "--show-toplevel" }))
end

local function git_branch(path)
  return first_line(git_systemlist({ "git", "-C", path, "symbolic-ref", "--short", "-q", "HEAD" }))
    or first_line(git_systemlist({ "git", "-C", path, "rev-parse", "--short", "HEAD" }))
    or "detached"
end

local function default_base_branch(repo)
  if git_systemlist({ "git", "-C", repo, "rev-parse", "--verify", "main" }) then
    return "main"
  end
  if git_systemlist({ "git", "-C", repo, "rev-parse", "--verify", "master" }) then
    return "master"
  end
  if git_systemlist({ "git", "-C", repo, "rev-parse", "--verify", "develop" }) then
    return "develop"
  end
  return "main"
end

local function parse_numstat(lines)
  local additions = 0
  local deletions = 0
  for _, line in ipairs(lines or {}) do
    local added, deleted = line:match("^(%d+)%s+(%d+)")
    additions = additions + (tonumber(added) or 0)
    deletions = deletions + (tonumber(deleted) or 0)
  end
  return additions, deletions
end

local function repository_worktree_stats(repo)
  local status = git_systemlist({ "git", "-C", repo, "status", "--porcelain", "--untracked-files=normal" })
  local additions, deletions = parse_numstat(git_systemlist({ "git", "-C", repo, "diff", "--numstat", "HEAD", "--" }))
  local untracked = git_systemlist({ "git", "-C", repo, "ls-files", "--others", "--exclude-standard" }) or {}
  for _, path in ipairs(untracked) do
    local output = vim.fn.systemlist({
      "git", "-C", repo, "diff", "--no-index", "--numstat", "--", "/dev/null", repo .. "/" .. path,
    })
    local added, deleted = parse_numstat(output)
    additions = additions + added
    deletions = deletions + deleted
  end
  return {
    has_diff = status ~= nil and #status > 0,
    additions = additions,
    deletions = deletions,
  }
end

local function repository_branch_stats(repo)
  local base = default_base_branch(repo)
  vim.fn.system({ "git", "-C", repo, "diff", "--quiet", base .. "...HEAD", "--" })
  local has_diff = vim.v.shell_error == 1
  local additions, deletions = parse_numstat(
    git_systemlist({ "git", "-C", repo, "diff", "--numstat", base .. "...HEAD", "--" })
  )
  return {
    has_diff = has_diff,
    additions = additions,
    deletions = deletions,
  }
end

local function list_child_git_repositories(parent, change_stats)
  local uv = vim.uv or vim.loop
  local scan = uv.fs_scandir(parent)
  if not scan then
    return {}
  end

  local repositories = {}
  while true do
    local name, entry_type = uv.fs_scandir_next(scan)
    if not name then
      break
    end

    local path = parent .. "/" .. name
    if (entry_type == "directory" or entry_type == "link")
      and uv.fs_stat(path .. "/.git")
      and vim.fn.isdirectory(path) == 1
    then
      local root = git_root(path)
      if root and (uv.fs_realpath(root) or root) == (uv.fs_realpath(path) or path) then
        local stats = change_stats and change_stats(root) or {}
        repositories[#repositories + 1] = {
          name = name,
          path = root,
          branch = git_branch(root),
          has_diff = stats.has_diff or false,
          additions = stats.additions or 0,
          deletions = stats.deletions or 0,
        }
      end
    end
  end

  recent_paths.sort(repositories, function(repository)
    return repository.path
  end, function(left, right)
    return left.name:lower() < right.name:lower()
  end)

  local changed = {}
  local clean = {}
  for _, repository in ipairs(repositories) do
    local target = repository.has_diff and changed or clean
    target[#target + 1] = repository
  end
  vim.list_extend(changed, clean)
  return changed
end

local repository_bar_namespace = vim.api.nvim_create_namespace("luanphan-diff-repositories")
local render_repository_bar

local function current_diffview(view)
  if view and view.tabpage and vim.api.nvim_tabpage_is_valid(view.tabpage) then
    return view
  end
  local ok, lib = pcall(require, "diffview.lib")
  return ok and lib.get_current_view() or nil
end

local function workspace_diff_state(view)
  view = current_diffview(view)
  return view and view._luanphan_workspace_diff or nil, view
end

local function focus_diff_content(view)
  local function focus()
    view = current_diffview(view)
    if not view or not view.tabpage or not vim.api.nvim_tabpage_is_valid(view.tabpage) then
      return false
    end
    local layout = view.cur_layout
    if not layout or type(layout.get_main_win) ~= "function" then
      return false
    end
    local ok, main = pcall(function()
      return layout:get_main_win()
    end)
    if not ok or not main or not main.id or not vim.api.nvim_win_is_valid(main.id) then
      return false
    end
    vim.api.nvim_set_current_tabpage(view.tabpage)
    vim.api.nvim_set_current_win(main.id)
    return true
  end

  if not focus() then
    vim.defer_fn(focus, 50)
  end
end

local function focus_repository_bar(state, index)
  local view = state.views and state.views[index] or nil
  local bar = state.bars and state.bars[index] or nil
  if not view or not view.tabpage or not vim.api.nvim_tabpage_is_valid(view.tabpage) then
    return false
  end
  if not bar or not vim.api.nvim_win_is_valid(bar.win) or not vim.api.nvim_buf_is_valid(bar.buf) then
    return false
  end

  vim.api.nvim_set_current_tabpage(view.tabpage)
  render_repository_bar(state, bar.buf, bar.win)
  vim.api.nvim_set_current_win(bar.win)
  return true
end

render_repository_bar = function(state, buf, win)
  local line = ""
  local ranges = {}
  local stat_ranges = {}
  for index, repository in ipairs(state.repositories) do
    if index > 1 then
      line = line .. "  "
    end
    local start_col = #line
    local selected = index == (state.selected or state.active)
    if selected then
      line = line .. "["
    end
    line = line .. repository.name
    if repository.has_diff then
      line = line .. " "
      local addition_start = #line
      line = line .. "+" .. tostring(repository.additions)
      local deletion_start = #line + 1
      line = line .. " -" .. tostring(repository.deletions)
      stat_ranges[index] = {
        addition = { start_col = addition_start, end_col = deletion_start - 1 },
        deletion = { start_col = deletion_start, end_col = #line },
      }
    end
    if selected then
      line = line .. "]"
    end
    ranges[index] = { start_col = start_col, end_col = #line }
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, repository_bar_namespace, 0, -1)
  for index, range in ipairs(ranges) do
    local group = "DiffviewRepoTabInactive"
    if index == (state.selected or state.active) then
      group = "DiffviewRepoTabSelected"
    elseif index == state.active then
      group = "DiffviewRepoTabActive"
    end
    vim.api.nvim_buf_add_highlight(buf, repository_bar_namespace, group, 0, range.start_col, range.end_col)
    local stats = stat_ranges[index]
    if stats then
      vim.api.nvim_buf_add_highlight(
        buf,
        repository_bar_namespace,
        "DiffviewFilePanelInsertions",
        0,
        stats.addition.start_col,
        stats.addition.end_col
      )
      vim.api.nvim_buf_add_highlight(
        buf,
        repository_bar_namespace,
        "DiffviewFilePanelDeletions",
        0,
        stats.deletion.start_col,
        stats.deletion.end_col
      )
    end
  end

  state.ranges = ranges
  local selected = ranges[state.selected or state.active]
  if selected and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_cursor(win, { 1, selected.start_col })
  end
end

local function repository_at_column(state, column)
  for index, range in ipairs(state.ranges or {}) do
    if column >= range.start_col and column < range.end_col then
      return index
    end
  end
  return nil
end

local function create_repository_bar(view, state, index, focus)
  if not view.tabpage or not vim.api.nvim_tabpage_is_valid(view.tabpage) then
    return
  end

  local previous_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_tabpage(view.tabpage)
  vim.cmd("topleft 1new")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buf, "workspace-diff://repositories/" .. tostring(view.tabpage))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "DiffviewRepoBar"
  vim.bo[buf].undofile = false
  vim.b[buf].luanphan_workspace_diff_bar = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].cursorline = false
  vim.wo[win].cursorcolumn = false
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].signcolumn = "no"
  vim.wo[win].statuscolumn = ""
  vim.wo[win].winfixheight = true
  vim.wo[win].wrap = false
  vim.wo[win].winhighlight = "Normal:TabLineFill,EndOfBuffer:TabLineFill"
  vim.api.nvim_win_set_height(win, 1)

  state.bars[index] = { buf = buf, win = win }
  render_repository_bar(state, buf, win)

  vim.keymap.set("n", "h", function()
    switch_workspace_diff(view, -1, false, false)
  end, { buffer = buf, desc = "Previous diff repository" })
  vim.keymap.set("n", "l", function()
    switch_workspace_diff(view, 1, false, false)
  end, { buffer = buf, desc = "Next diff repository" })
  vim.keymap.set("n", "<Left>", function()
    switch_workspace_diff(view, -1, false, false)
  end, { buffer = buf, desc = "Previous diff repository" })
  vim.keymap.set("n", "<Right>", function()
    switch_workspace_diff(view, 1, false, false)
  end, { buffer = buf, desc = "Next diff repository" })
  vim.keymap.set("n", "<LeftMouse>", function()
    local mouse = vim.fn.getmousepos()
    if mouse.winid == win then
      switch_workspace_diff(view, repository_at_column(state, math.max(mouse.column - 1, 0)), true, false)
    end
  end, { buffer = buf, desc = "Open diff repository" })
  vim.keymap.set("n", "q", function()
    close_workspace_diff(view)
  end, { buffer = buf, silent = true, desc = "Close Diffview" })
  set_diffview_keymaps(view, buf)

  if focus == "diff" then
    focus_diff_content(view)
  elseif focus == "bar" then
    focus_repository_bar(state, index)
  elseif vim.api.nvim_win_is_valid(previous_win) then
    vim.api.nvim_set_current_win(previous_win)
  end
end

local function attach_workspace_diff(view)
  local pending = pending_workspace_diff
  if not pending or not pending.state or #pending.state.repositories < 2 then
    return
  end

  local state = pending.state
  local index = pending.index
  local repository = state.repositories[index]
  local root = view.adapter and view.adapter.ctx and view.adapter.ctx.toplevel
  if not repository or not same_real_path(root, repository.path) then
    return
  end

  pending_workspace_diff = nil
  state.active = index
  state.selected = index
  state.views[index] = view
  view._luanphan_workspace_diff = state
  view._luanphan_workspace_diff_index = index
  create_repository_bar(view, state, index, pending.focus)
end

local function open_workspace_diff(parent, repositories, action)
  if #repositories == 0 then
    vim.notify("no immediate child git repositories found", vim.log.levels.WARN)
    return
  end
  if #repositories == 1 then
    recent_paths.touch(repositories[1].path)
    action(repositories[1].path)
    return
  end

  local state = {
    parent = parent,
    repositories = repositories,
    active = 1,
    selected = 1,
    open = action,
    views = {},
    bars = {},
  }
  pending_workspace_diff = { state = state, index = 1, focus = "initial" }
  recent_paths.touch(repositories[1].path)
  action(repositories[1].path)
end

switch_workspace_diff = function(view, target, absolute, focus_diff)
  local state
  state, view = workspace_diff_state(view)
  if not state then
    return
  end

  local count = #state.repositories
  local index = absolute and target or ((state.active - 1 + target) % count) + 1
  if not index or not state.repositories[index] then
    return
  end

  state.active = index
  state.selected = index
  recent_paths.touch(state.repositories[index].path)

  local target_view = state.views[index]
  if target_view and target_view.tabpage and vim.api.nvim_tabpage_is_valid(target_view.tabpage) then
    if focus_diff then
      focus_diff_content(target_view)
    else
      focus_repository_bar(state, index)
    end
    return
  end

  pending_workspace_diff = {
    state = state,
    index = index,
    focus = focus_diff and "diff" or "bar",
  }
  focus_diff_content(view)
  vim.schedule(function()
    local ok, err = pcall(state.open, state.repositories[index].path)
    if not ok then
      pending_workspace_diff = nil
      vim.notify("Could not switch diff repository: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

close_workspace_diff = function(view)
  view = current_diffview(view)
  local state = view and view._luanphan_workspace_diff or nil
  if not state then
    vim.cmd("DiffviewClose")
    return
  end

  local ok, lib = pcall(require, "diffview.lib")
  if not ok then
    return
  end

  local target_tab = lib.get_prev_non_view_tabpage()
  local views = {}
  for _, retained in pairs(state.views) do
    views[#views + 1] = retained
  end
  table.sort(views, function(left, right)
    local left_number = left.tabpage and vim.api.nvim_tabpage_is_valid(left.tabpage)
      and vim.api.nvim_tabpage_get_number(left.tabpage) or -1
    local right_number = right.tabpage and vim.api.nvim_tabpage_is_valid(right.tabpage)
      and vim.api.nvim_tabpage_get_number(right.tabpage) or -1
    return left_number > right_number
  end)

  state.closing = true
  for _, retained in ipairs(views) do
    if retained.tabpage and vim.api.nvim_tabpage_is_valid(retained.tabpage) then
      retained:close()
    end
    lib.dispose_view(retained)
  end
  state.views = {}
  state.bars = {}
  if target_tab and vim.api.nvim_tabpage_is_valid(target_tab) then
    vim.api.nvim_set_current_tabpage(target_tab)
  end
end

local function close_current_diffview()
  local ok, lib = pcall(require, "diffview.lib")
  local view = ok and lib.get_current_view() or nil
  if view and view._luanphan_workspace_diff then
    close_workspace_diff(view)
  else
    vim.cmd("DiffviewClose")
  end
end

local function with_diff_repository(action, has_diff)
  return function()
    if close_or_focus_existing_diffview() then
      return
    end

    local cwd = vim.fn.getcwd()
    local root = git_root(cwd)
    if root then
      recent_paths.touch(root)
      action(root)
      return
    end
    open_workspace_diff(cwd, list_child_git_repositories(cwd, has_diff), action)
  end
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

local function open_branch_diff(repo)
  open_diffview(repo, default_base_branch(repo) .. "...HEAD")
end

local function with_diffview(fn)
  return function()
    require("lazy").load({ plugins = { "diffview.nvim" } })
    fn()
  end
end

local function setup_diffview_keymaps()
  vim.keymap.set("n", "<leader>gd", with_diffview(with_diff_repository(function(repo)
    open_diffview(repo)
  end, repository_worktree_stats)), { desc = "Diff current changes" })
  vim.keymap.set("n", "<leader>gD", with_diffview(with_diff_repository(
    open_branch_diff,
    repository_branch_stats
  )), { desc = "Diff branch vs base" })
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
      vim.api.nvim_set_hl(0, "DiffviewRepoTabSelected", { link = "TabLineSel", default = true })
      vim.api.nvim_set_hl(0, "DiffviewRepoTabActive", { link = "DiffText", default = true })
      vim.api.nvim_set_hl(0, "DiffviewRepoTabInactive", { link = "TabLine", default = true })
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

            set_diffview_tab_keymaps(view)
            set_diffview_keymaps(view, 0)
            preserve_diffview_folds(view)
            attach_workspace_diff(view)
            vim.schedule(function()
              set_diffview_tab_keymaps(view)
            end)
          end,
          view_closed = function(view)
            local state = view._luanphan_workspace_diff
            local index = view._luanphan_workspace_diff_index
            if state and index and state.views[index] == view then
              state.views[index] = nil
              state.bars[index] = nil
            end
          end,
        },
      })


      -- Close diffview with q in any diffview buffer
      vim.api.nvim_create_autocmd("BufEnter", {
        callback = function()
          local bufname = vim.api.nvim_buf_get_name(0)
          if bufname:match("diffview://") then
            vim.keymap.set("n", "q", close_current_diffview, { buffer = true, silent = true })
          end
          if current_tab_has_diffview() then
            set_diffview_keymaps(nil, 0)
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
