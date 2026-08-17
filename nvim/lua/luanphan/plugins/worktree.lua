local LAST_CWD_KEY = "luanphan_workspace_last_cwd"

local api = nil

local function remember_cwd()
  local ok, cwd = pcall(vim.fn.getcwd)
  if ok and cwd and cwd ~= "" then
    vim.g[LAST_CWD_KEY] = cwd:gsub("/$", "")
  end
end

local function init()
  remember_cwd()
  vim.api.nvim_create_autocmd({ "VimEnter", "DirChanged" }, {
    group = vim.api.nvim_create_augroup("LuanphanWorktreeLastCwd", { clear = true }),
    callback = remember_cwd,
  })
end

local function setup()
  -- Pure telescope + git CLI; no external plugin.
  -- Requires are deferred into the function so module load doesn't touch
  -- telescope (which is loaded by the plugin manager).

  -- Per-cwd buffer state. In-memory only (vim.g key) so it survives the
  -- switch but not an nvim restart. Map shape:
  --   { [cwd] = {
  --       files     = { abs_paths… },
  --       positions = { [abs_path] = { line, col }, … },  -- per-file cursor
  --       active    = abs_path|nil,
  --       jumps     = { { path, line, col }, … },
  --     } }
  local BUFSTORE_KEY = "luanphan_workspace_buffers"
  local WS_CONTAINER = "local_workspaces"
  local AGENT_BUFFER_KEYS = {
    { name = "codex", key = "codex_agent_bufnr" },
    { name = "claude", key = "claude_agent_bufnr" },
    { name = "cursor", key = "cursor_agent_bufnr" },
  }
  local recent_paths = require("luanphan.recent_paths")

  -- Transient map of "apply this cursor when the file is first BufReadPost'd
  -- in the current nvim session". Populated by `restore_buffers`, consumed
  -- by the autocmd below on first read. Keyed by absolute path.
  local PENDING_POS_KEY = "luanphan_workspace_pending_positions"

  vim.api.nvim_create_autocmd("BufReadPost", {
    group = vim.api.nvim_create_augroup("LuanphanWorktreeRestorePos", { clear = true }),
    callback = function(args)
      local pending = vim.g[PENDING_POS_KEY] or {}
      local name = vim.api.nvim_buf_get_name(args.buf)
      if name == "" then return end
      local pos = pending[name]
      if not pos then return end
      -- Find a window showing this buffer (BufReadPost runs in the buffer's
      -- context but not always in a window, e.g. for badd-loaded buffers).
      local win = nil
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(w) == args.buf then
          win = w; break
        end
      end
      if win then
        local lc = vim.api.nvim_buf_line_count(args.buf)
        local line = math.min(math.max(1, pos.line or 1), lc)
        pcall(vim.api.nvim_win_set_cursor, win, { line, pos.col or 0 })
      end
      pending[name] = nil
      vim.g[PENDING_POS_KEY] = pending
    end,
  })

  -- Currently-focused file (or any visible file window) at snapshot time, so
  -- we can re-open it in an editor window when the user comes back.
  local function find_active_file()
    local cur = vim.api.nvim_get_current_buf()
    if vim.bo[cur].buftype == "" then
      local name = vim.api.nvim_buf_get_name(cur)
      if name ~= "" and vim.fn.filereadable(name) == 1 then
        return name
      end
    end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].buftype == "" and vim.bo[buf].filetype ~= "NvimTree" then
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= "" and vim.fn.filereadable(name) == 1 then
          return name
        end
      end
    end
    return nil
  end

  -- Best-effort cursor position for a buffer:
  --   1. If a window currently shows it → live cursor
  --   2. Else if the `"` mark exists (buf was visited earlier this session)
  --      → that mark
  --   3. Else nil (no info; restore will land at line 1)
  local function buffer_cursor(buf)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == buf then
        local cur = vim.api.nvim_win_get_cursor(win)
        return { line = cur[1], col = cur[2] }
      end
    end
    local ok, mark = pcall(vim.api.nvim_buf_get_mark, buf, '"')
    if ok and mark and mark[1] and mark[1] > 0 then
      return { line = mark[1], col = mark[2] or 0 }
    end
    return nil
  end

  local function snapshot_buffers(cwd)
    -- Use `buflisted` (not `nvim_buf_is_loaded`) so that files re-added by a
    -- previous restore — which `:badd`s into the listed-but-unloaded state —
    -- still survive the round-trip.
    local files = {}
    local positions = {}
    local seen = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].buflisted and vim.bo[buf].buftype == "" then
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= "" and vim.fn.filereadable(name) == 1 and not seen[name] then
          seen[name] = true
          files[#files + 1] = name
          local pos = buffer_cursor(buf)
          if pos then positions[name] = pos end
        end
      end
    end

    local store = vim.g[BUFSTORE_KEY] or {}
    local prev = store[cwd]
    local prev_active = type(prev) == "table" and prev.active or nil
    local prev_positions = type(prev) == "table" and prev.positions or nil

    -- Prefer the currently-focused file. If the user happened to be on a
    -- [No Name] / tree / picker buffer when pressing <leader>ww, fall back
    -- to whatever was active last time (if it's still in the files list).
    local active = find_active_file()
    if not active and prev_active and seen[prev_active] then
      active = prev_active
    end

    -- Carry over positions for files we couldn't read live cursors for
    -- (typically because they were already unloaded and didn't have a `"`
    -- mark either) — keeps the cursor memory across switches even when the
    -- buffer never got opened in this session.
    if prev_positions then
      for path, pos in pairs(prev_positions) do
        if seen[path] and positions[path] == nil then
          positions[path] = pos
        end
      end
    end

    store[cwd] = { files = files, positions = positions, active = active }
    vim.g[BUFSTORE_KEY] = store
  end

  -- Find an editor window (real file buftype, not NvimTree, not a terminal)
  -- so we have a place to `:edit` the restored active file without hijacking
  -- the tree pane. Returns nil if there is no editor window left.
  local function find_editor_window()
    local function is_editor(win)
      local buf = vim.api.nvim_win_get_buf(win)
      local bt = vim.bo[buf].buftype
      local ft = vim.bo[buf].filetype
      return bt == "" and ft ~= "NvimTree"
    end

    local current = vim.api.nvim_get_current_win()
    if is_editor(current) then
      return current
    end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if is_editor(win) then
        return win
      end
    end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if is_editor(win) then
        return win
      end
    end
    return nil
  end

  local function jump_path(jump)
    if jump.bufnr and jump.bufnr > 0 and vim.api.nvim_buf_is_valid(jump.bufnr) then
      local name = vim.api.nvim_buf_get_name(jump.bufnr)
      if name ~= "" then
        return name
      end
    end
    if type(jump.filename) == "string" and jump.filename ~= "" then
      return vim.fn.fnamemodify(jump.filename, ":p")
    end
    return nil
  end

  local function snapshot_jumplist(cwd)
    local win = find_editor_window()
    if not win then return end

    local ok, result = pcall(vim.api.nvim_win_call, win, function()
      return vim.fn.getjumplist()
    end)
    if not ok or type(result) ~= "table" then return end

    local list = result[1] or {}
    local index = math.min(result[2] or #list, #list)
    local jumps = {}
    for i = 1, index do
      local jump = list[i]
      local path = jump_path(jump)
      if path and vim.fn.filereadable(path) == 1 then
        local normalized = vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
        local root = vim.fn.fnamemodify(cwd, ":p"):gsub("/$", "")
        if normalized == root or vim.startswith(normalized, root .. "/") then
          jumps[#jumps + 1] = {
            path = normalized,
            line = jump.lnum or 1,
            col = jump.col or 0,
          }
        end
      end
    end

    local store = vim.g[BUFSTORE_KEY] or {}
    store[cwd] = type(store[cwd]) == "table" and store[cwd] or {}
    store[cwd].jumps = jumps
    vim.g[BUFSTORE_KEY] = store
  end

  -- Visible agent float for the current cwd. Toggleterm splits also set
  -- `luanphan_persist_term`, so only floating windows qualify here.
  local function find_agent_float()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg.relative and cfg.relative ~= "" then
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.b[buf].luanphan_persist_term and not vim.b[buf].luanphan_toggleterm then
          return win
        end
      end
    end
    return nil
  end

  local function close_other_agent_windows(target_bufnr)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) then
        local buf = vim.api.nvim_win_get_buf(win)
        if buf ~= target_bufnr
          and vim.bo[buf].buftype == "terminal"
          and vim.b[buf].luanphan_persist_term
          and not vim.b[buf].luanphan_toggleterm
        then
          pcall(vim.api.nvim_win_close, win, false)
        end
      end
    end
  end

  local function find_tree_window()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == "NvimTree" then
        return win
      end
    end
    return nil
  end

  local function tab_has_diffview(tabid)
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabid)) do
      local bufname = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(winid))
      if bufname:match("^diffview://") then
        return true
      end
    end
    return false
  end

  local function close_diffview_tabs()
    local original = vim.api.nvim_get_current_tabpage()
    local tabs = {}
    for _, tabid in ipairs(vim.api.nvim_list_tabpages()) do
      if tab_has_diffview(tabid) then
        tabs[#tabs + 1] = tabid
      end
    end

    for _, tabid in ipairs(tabs) do
      if vim.api.nvim_tabpage_is_valid(tabid) then
        local tabnr = vim.api.nvim_tabpage_get_number(tabid)
        pcall(vim.api.nvim_set_current_tabpage, tabid)
        pcall(vim.cmd, "DiffviewClose")
        if vim.api.nvim_tabpage_is_valid(tabid) then
          pcall(vim.cmd, "tabclose! " .. tabnr)
        end
      end
    end

    if vim.api.nvim_tabpage_is_valid(original) then
      pcall(vim.api.nvim_set_current_tabpage, original)
    end
  end

  local function path_is_in_dir(path, dir)
    if path == dir then return true end
    if dir:sub(-1) == "/" then
      return vim.startswith(path, dir)
    end
    return vim.startswith(path, dir .. "/")
  end

  local function safe_getcwd()
    local ok, cwd = pcall(vim.fn.getcwd)
    if ok and cwd and cwd ~= "" then
      cwd = cwd:gsub("/$", "")
      vim.g[LAST_CWD_KEY] = cwd
      return cwd
    end
    local last = vim.g[LAST_CWD_KEY]
    if type(last) == "string" and last ~= "" then
      return last:gsub("/$", "")
    end
    return ""
  end

  local function dir_exists(path)
    if path == "" then
      return false
    end
    local stat = (vim.uv or vim.loop).fs_stat(path)
    return stat and stat.type == "directory" or false
  end

  local function git_repo_exists(path)
    if not dir_exists(path) then
      return false
    end
    return vim.fn.isdirectory(path .. "/.git") == 1 or vim.fn.filereadable(path .. "/.git") == 1
  end

  local function git_root(path)
    local lines = vim.fn.systemlist({ "git", "-C", path, "rev-parse", "--show-toplevel" })
    if vim.v.shell_error ~= 0 or not lines or not lines[1] or lines[1] == "" then
      return nil
    end
    return lines[1]:gsub("/$", "")
  end

  local function infer_master_worktree_from_workspace_path(path)
    local pattern = "^(.-)/" .. WS_CONTAINER .. "/([^/]+)/([^/]+)(/.*)$"
    local root, _, repo = path:match(pattern)
    if not root then
      root, _, repo = path:match("^(.-)/" .. WS_CONTAINER .. "/([^/]+)/([^/]+)$")
    end
    if not root or not repo then
      return nil
    end

    local source = root .. "/" .. repo
    if not git_repo_exists(source) then
      return nil
    end

    return source
  end

  local function workspace_path_from_buffers()
    local bufs = { vim.api.nvim_get_current_buf() }
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      bufs[#bufs + 1] = buf
    end
    for _, buf in ipairs(bufs) do
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and name:find("/" .. WS_CONTAINER .. "/", 1, true) then
        return vim.fn.fnamemodify(name, ":h"):gsub("/$", "")
      end
    end
    return ""
  end

  local function nearest_existing_parent(path)
    local p = path:gsub("/+$", "")
    while p ~= "" and p ~= "/" do
      p = vim.fn.fnamemodify(p, ":h")
      if dir_exists(p) then
        return p
      end
    end
    return dir_exists("/") and "/" or nil
  end

  local switch_to

  local function rescue_deleted_cwd()
    local cwd = safe_getcwd()
    if cwd == "" then
      cwd = workspace_path_from_buffers()
    end
    if cwd == "" or dir_exists(cwd) then
      return false
    end

    local master = infer_master_worktree_from_workspace_path(cwd)
    if master then
      vim.notify("Current worktree was removed; switching to master worktree: " .. master, vim.log.levels.WARN)
      switch_to(master)
      return true
    end

    local parent = nearest_existing_parent(cwd)
    if parent then
      vim.notify("Current cwd was removed; cd to nearest existing parent: " .. parent, vim.log.levels.WARN)
      pcall(vim.cmd, "cd " .. vim.fn.fnameescape(parent))
    end
    return false
  end

  local function clear_all_jumplists()
    local original_tab = vim.api.nvim_get_current_tabpage()
    local original_win = vim.api.nvim_get_current_win()

    for _, tabid in ipairs(vim.api.nvim_list_tabpages()) do
      if vim.api.nvim_tabpage_is_valid(tabid) then
        pcall(vim.api.nvim_set_current_tabpage, tabid)
        for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabid)) do
          if vim.api.nvim_win_is_valid(winid) then
            pcall(vim.api.nvim_set_current_win, winid)
            pcall(vim.cmd, "clearjumps")
          end
        end
      end
    end

    if vim.api.nvim_tabpage_is_valid(original_tab) then
      pcall(vim.api.nvim_set_current_tabpage, original_tab)
    end
    if vim.api.nvim_win_is_valid(original_win) then
      pcall(vim.api.nvim_set_current_win, original_win)
    end
  end

  local function restore_jumplist(cwd, active_path)
    clear_all_jumplists()

    local store = vim.g[BUFSTORE_KEY] or {}
    local entry = store[cwd]
    local jumps = type(entry) == "table" and entry.jumps or nil
    if not jumps or #jumps == 0 or not active_path then return end

    local win = find_editor_window()
    if not win then return end
    local active_pos = type(entry.positions) == "table" and entry.positions[active_path] or nil

    pcall(vim.api.nvim_win_call, win, function()
      local scratch_buffers = {}
      for _, jump in ipairs(jumps) do
        if vim.fn.filereadable(jump.path) == 1
          and pcall(vim.cmd, "keepjumps hide edit " .. vim.fn.fnameescape(jump.path))
        then
          local line = math.min(math.max(1, jump.line or 1), vim.api.nvim_buf_line_count(0))
          pcall(vim.api.nvim_win_set_cursor, 0, { line, jump.col or 0 })
          if pcall(vim.cmd, "hide enew") then
            scratch_buffers[#scratch_buffers + 1] = vim.api.nvim_get_current_buf()
          end
        end
      end

      pcall(vim.cmd, "keepjumps hide edit " .. vim.fn.fnameescape(active_path))
      if active_pos then
        local line = math.min(math.max(1, active_pos.line or 1), vim.api.nvim_buf_line_count(0))
        pcall(vim.api.nvim_win_set_cursor, 0, { line, active_pos.col or 0 })
      end
      for _, buf in ipairs(scratch_buffers) do
        if vim.api.nvim_buf_is_valid(buf) and buf ~= vim.api.nvim_get_current_buf() then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
      end
    end)
  end

  local function close_toggleterm_windows()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) then
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.b[buf].luanphan_toggleterm or vim.b[buf].toggle_number then
          pcall(vim.api.nvim_win_close, win, false)
        end
      end
    end
  end

  -- Focus priority after a switch:
  --   1. visible agent float
  --   2. window showing the file we just re-opened
  --   3. nvim-tree
  -- If none match, focus stays wherever the last step left it.
  local function focus_after_switch(reopened_path)
    local agent = find_agent_float()
    if agent then
      pcall(vim.api.nvim_set_current_win, agent)
      vim.defer_fn(function()
        if vim.api.nvim_get_current_win() == agent and vim.bo.buftype == "terminal" then
          vim.cmd("startinsert")
        end
      end, 10)
      return
    end
    if reopened_path then
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.api.nvim_buf_get_name(buf) == reopened_path then
          pcall(vim.api.nvim_set_current_win, win)
          return
        end
      end
    end
    local tree = find_tree_window()
    if tree then
      pcall(vim.api.nvim_set_current_win, tree)
    end
  end

  local function restore_buffers(cwd)
    local store = vim.g[BUFSTORE_KEY] or {}
    local entry = store[cwd]
    if not entry then return 0, nil end

    -- Tolerate either the new struct or the old flat-list format.
    local files = (type(entry) == "table" and entry.files) or entry
    local active = type(entry) == "table" and entry.active or nil
    local positions = type(entry) == "table" and entry.positions or {}
    if not files or #files == 0 then return 0, nil end

    local restored = 0
    for _, path in ipairs(files) do
      if vim.fn.filereadable(path) == 1 then
        if pcall(vim.cmd, "badd " .. vim.fn.fnameescape(path)) then
          restored = restored + 1
        end
      end
    end

    -- Stage the per-file cursors into the pending map; the BufReadPost
    -- autocmd above applies them when each file is first read into memory
    -- (which happens lazily when the user actually navigates to it).
    if positions then
      local pending = vim.g[PENDING_POS_KEY] or {}
      for path, pos in pairs(positions) do
        if vim.fn.filereadable(path) == 1 then
          pending[path] = pos
        end
      end
      vim.g[PENDING_POS_KEY] = pending
    end

    -- Pick what to re-open: prefer the saved `active`, but fall back to the
    -- first file in the saved list if `active` is missing or unreadable.
    local target_file = nil
    if active and vim.fn.filereadable(active) == 1 then
      target_file = active
    else
      for _, path in ipairs(files) do
        if vim.fn.filereadable(path) == 1 then
          target_file = path
          break
        end
      end
    end

    local opened_active = false
    if target_file then
      local target_win = find_editor_window()
      if target_win then
        pcall(vim.api.nvim_set_current_win, target_win)
        if pcall(vim.cmd, "edit " .. vim.fn.fnameescape(target_file)) then
          opened_active = true
          -- Apply the saved cursor for the active file directly. The
          -- BufReadPost autocmd may have already done this if it fired
          -- during :edit, but applying again here is idempotent and
          -- handles the case where :edit reuses an already-loaded buffer
          -- (no BufReadPost). Clamp to current line count so a stale
          -- saved line past EOF doesn't error.
          local pos = positions and positions[target_file]
          if pos then
            local lc = vim.api.nvim_buf_line_count(0)
            local line = math.min(math.max(1, pos.line or 1), lc)
            pcall(vim.api.nvim_win_set_cursor, 0, { line, pos.col or 0 })
            -- Drain from the pending map so it doesn't fire later.
            local pending = vim.g[PENDING_POS_KEY] or {}
            pending[target_file] = nil
            vim.g[PENDING_POS_KEY] = pending
          end
        end
      end
    end

    return restored, opened_active and target_file or nil
  end

  -- Re-trigger FileType on every loaded normal buffer so vim.lsp.enable's
  -- per-config FileType autocmd attaches a fresh LSP client. Mirrors
  -- `lsp_restart.refire_filetype(nil)` but inlined so this module stays
  -- self-contained.
  local function refire_filetype_all()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
        pcall(vim.api.nvim_buf_call, buf, function()
          vim.api.nvim_exec_autocmds("FileType", { buffer = buf })
        end)
      end
    end
  end

  local function list_worktrees()
    local handle = io.popen("git worktree list --porcelain 2>/dev/null")
    if not handle then return {} end
    local out = handle:read("*a") or ""
    handle:close()

    local trees = {}
    local cur = {}
    for _, line in ipairs(vim.split(out, "\n")) do
      if line == "" then
        if cur.path then
          table.insert(trees, cur)
          cur = {}
        end
      elseif line:match("^worktree ") then
        cur.path = line:sub(10)
      elseif line:match("^HEAD ") then
        cur.head = line:sub(6, 12)
      elseif line:match("^branch ") then
        cur.branch = line:sub(8):gsub("^refs/heads/", "")
      elseif line == "detached" then
        cur.detached = true
      end
    end
    if cur.path then table.insert(trees, cur) end
    return recent_paths.sort(trees, function(tree)
      return tree.path
    end)
  end

  local function list_repos_in_dir(parent)
    local uv = vim.uv or vim.loop
    local handle = uv.fs_scandir(parent)
    if not handle then
      return {}
    end

    local repos = {}
    while true do
      local name = uv.fs_scandir_next(handle)
      if not name then break end
      local path = parent .. "/" .. name
      if git_repo_exists(path) then
        repos[#repos + 1] = { name = name, path = path }
      end
    end
    return recent_paths.sort(repos, function(repo)
      return repo.path
    end, function(a, b)
      return a.name < b.name
    end)
  end

  local function list_sibling_repos()
    local root = git_root(safe_getcwd())
    if not root then
      return {}, nil
    end

    local parent = vim.fn.fnamemodify(root, ":h")
    local repos = list_repos_in_dir(parent)
    return repos, root
  end

  local function project_branch(path)
    local lines = vim.fn.systemlist({ "git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD" })
    if vim.v.shell_error ~= 0 or not lines or not lines[1] or lines[1] == "" then
      return "HEAD"
    end
    return lines[1]
  end

  local function list_all_project_repos()
    local siblings, current_root = list_sibling_repos()
    local marker = "/" .. WS_CONTAINER .. "/"
    local cwd = safe_getcwd()
    local marker_path = current_root or cwd
    local marker_start = marker_path:find(marker, 1, true)
    local repos = {}
    local seen = {}

    local function append(candidates, scope)
      for _, repo in ipairs(candidates) do
        if not seen[repo.path] then
          seen[repo.path] = true
          repos[#repos + 1] = {
            name = repo.name,
            path = repo.path,
            branch = project_branch(repo.path),
            scope = scope,
          }
        end
      end
    end

    if current_root then
      append(siblings, marker_start and "workspace" or "root")
      if marker_start then
        append(list_repos_in_dir(current_root:sub(1, marker_start - 1)), "root")
      end
      return repos, current_root
    end

    if not marker_start then
      return {}, nil
    end

    local workstation = cwd:sub(1, marker_start - 1)
    local workspace_name = cwd:sub(marker_start + #marker):match("^([^/]+)")
    if not workspace_name then
      return {}, nil
    end

    local workspace = workstation .. marker .. workspace_name
    append(list_repos_in_dir(workspace), "workspace")
    append(list_repos_in_dir(workstation), "root")
    return repos, workspace
  end

  local function workstation_root()
    local cwd = safe_getcwd()
    if cwd == "" then
      return nil
    end

    local marker = "/" .. WS_CONTAINER .. "/"
    local marker_start = cwd:find(marker, 1, true)
    if marker_start then
      return cwd:sub(1, marker_start - 1)
    end

    if dir_exists(cwd .. "/" .. WS_CONTAINER) then
      return cwd
    end

    local root = git_root(cwd)
    if not root then
      return nil
    end
    marker_start = root:find(marker, 1, true)
    if marker_start then
      return root:sub(1, marker_start - 1)
    end
    return vim.fn.fnamemodify(root, ":h")
  end

  local function list_workspace_directories()
    local root = workstation_root()
    if not root then
      return {}, nil
    end

    local container = root .. "/" .. WS_CONTAINER
    local uv = vim.uv or vim.loop
    local handle = uv.fs_scandir(container)
    if not handle then
      return {}, root
    end

    local workspaces = {}
    while true do
      local name = uv.fs_scandir_next(handle)
      if not name then break end
      local path = container .. "/" .. name
      if dir_exists(path) then
        local repos = list_repos_in_dir(path)
        workspaces[#workspaces + 1] = {
          name = name,
          path = path,
          repos = repos,
          empty = #repos == 0,
        }
      end
    end
    recent_paths.sort(workspaces, function(workspace)
      return workspace.path
    end, function(a, b)
      return a.name < b.name
    end)
    return workspaces, root
  end

  local function group_project_entries(repos, current_root)
    local name_width = 0
    for _, repo in ipairs(repos) do
      name_width = math.max(name_width, #repo.name)
    end

    local entries = {}
    for _, scope in ipairs({ "workspace", "root" }) do
      local scoped = {}
      for _, repo in ipairs(repos) do
        if repo.scope == scope then
          scoped[#scoped + 1] = repo
        end
      end
      if #scoped > 0 then
        entries[#entries + 1] = {
          header = true,
          scope = scope,
          display = "[" .. scope .. "]",
          ordinal = scope,
          order = #entries + 1,
        }
        for _, repo in ipairs(scoped) do
          local marker = repo.path == current_root and "* " or "  "
          entries[#entries + 1] = vim.tbl_extend("force", repo, {
            display = string.format("%s%-" .. name_width .. "s [%s]", marker, repo.name, repo.branch),
            ordinal = repo.name,
            order = #entries + 1,
          })
        end
      end
    end
    return entries
  end

  local function make_project_sorter(base_sorter, sorters)
    return sorters.Sorter:new({
      scoring_function = function(_, prompt, line, entry)
        local value = entry.value
        local group_offset = value.scope == "root" and 10 or 0
        if value.header then
          return group_offset
        end

        local score = base_sorter:scoring_function(prompt, line, entry)
        if not score or score < 0 then
          return -1
        end
        if prompt == "" then
          return group_offset + 1 + value.order / 10000
        end
        return group_offset + 1 + score + value.order / 10000
      end,
      highlighter = function(_, prompt, display)
        return base_sorter:highlighter(prompt, display)
      end,
    })
  end

  local function move_project_selection(picker, delta)
    local count = picker.manager and picker.manager:num_results() or 0
    for _ = 1, count do
      picker:move_selection(delta)
      local selection = picker:get_selection()
      if not selection or not selection.value or not selection.value.header then
        return
      end
    end
  end

  local function terminal_job_running(bufnr)
    if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
      return false
    end
    if vim.bo[bufnr].buftype ~= "terminal" then
      return false
    end
    local job = vim.b[bufnr].terminal_job_id
    if type(job) ~= "number" or job <= 0 then
      return false
    end
    local ok, status = pcall(vim.fn.jobwait, { job }, 0)
    return ok and status[1] == -1
  end

  local function list_active_agents()
    local agent_status = require("luanphan.agent_status")
    local instances = {}
    for _, agent in ipairs(AGENT_BUFFER_KEYS) do
      local buffers = vim.g[agent.key]
      if type(buffers) == "table" then
        for cwd, bufnr in pairs(buffers) do
          if type(cwd) == "string" and dir_exists(cwd) and terminal_job_running(bufnr) then
            local root = git_root(cwd) or cwd
            local context = vim.fn.fnamemodify(root, ":t")
            local marker = "/" .. WS_CONTAINER .. "/"
            local marker_start = root:find(marker, 1, true)
            if marker_start then
              local workspace = root:sub(marker_start + #marker):match("^([^/]+)")
              if workspace then
                context = workspace .. "/" .. context
              end
            end
            if cwd ~= root and path_is_in_dir(cwd, root) then
              context = context .. "/" .. cwd:sub(#root + 2)
            end
            instances[#instances + 1] = {
              agent = agent.name,
              branch = project_branch(root),
              bufnr = bufnr,
              context = context,
              path = cwd,
              status = agent_status.read(agent.name, cwd),
            }
          end
        end
      end
    end

    recent_paths.sort(instances, function(instance)
      return instance.path
    end, function(a, b)
      if a.context == b.context then
        return a.agent < b.agent
      end
      return a.context < b.context
    end)

    local agent_width = 0
    local status_width = 0
    local context_width = 0
    local current = safe_getcwd()
    for _, instance in ipairs(instances) do
      agent_width = math.max(agent_width, #instance.agent)
      status_width = math.max(status_width, #instance.status)
      context_width = math.max(context_width, #instance.context)
    end
    for _, instance in ipairs(instances) do
      local marker = instance.path == current and "* " or "  "
      instance.display = string.format(
        "%s%-" .. agent_width .. "s  [%-" .. status_width .. "s]  %-" .. context_width .. "s  [%s]",
        marker,
        instance.agent,
        instance.status,
        instance.context,
        instance.branch
      )
      instance.ordinal = instance.agent .. " " .. instance.context
    end
    return instances
  end

  switch_to = function(path, kind, visit_path)
    if vim.fn.isdirectory(path) == 0 then
      vim.notify("worktree path not found: " .. path, vim.log.levels.ERROR)
      return
    end

    -- 1. Snapshot the OLD cwd's open file list before we touch anything else.
    --    Lets us restore the same buffer list when the user returns later.
    local old_cwd = safe_getcwd()
    if old_cwd ~= "" then
      snapshot_buffers(old_cwd)
      snapshot_jumplist(old_cwd)
    end

    -- 2a. Close nvim-tree first if it's open. The tree pane has its own
    --     buffer-list / cwd-tracking quirks (auto-attach, change_root timing,
    --     window-pick fallback) that have repeatedly interfered with the
    --     cleanup+restore steps below. Easier to take it out of the loop
    --     entirely and pop it back open at the end with the new cwd.
    local ok_tree, tree_api = pcall(require, "nvim-tree.api")
    local tree_was_open = false
    if ok_tree then
      local ok_vis, vis = pcall(tree_api.tree.is_visible)
      tree_was_open = ok_vis and vis or false
      if tree_was_open then
        pcall(tree_api.tree.close)
      end
    end

    -- 2b. Close any open diffview tab — it's bound to the OLD cwd's git
    --     repo and trying to survive the cd produces ghost diffview://
    --     buffers that won't refresh against the new worktree.
    close_diffview_tabs()

    -- 2c. Toggle off the right-side toggleterm terminal before changing cwd.
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "LuanphanWorktreeSwitchPre" })
    close_toggleterm_windows()

    -- 3. cd. Fires DirChangedPre/DirChanged for the persistent-terminal modules.
    vim.cmd("cd " .. vim.fn.fnameescape(path))
    recent_paths.touch(visit_path or path)

    -- 4. Stop every LSP client AND wipe the diagnostics each one published.
    --    `client:stop()` alone leaves stale diagnostics painted on any buffer
    --    that survives the cd (same path prefix) — then the new-worktree LSP
    --    layers fresh diagnostics on top, so lines that are clean in the new
    --    code still show warnings/errors from the old client's extmarks.
    for _, client in pairs(vim.lsp.get_clients()) do
      local ok_ns, ns = pcall(vim.lsp.diagnostic.get_namespace, client.id)
      if ok_ns and ns then
        pcall(vim.diagnostic.reset, ns)
      end
      client:stop()
    end
    -- Belt-and-suspenders: non-LSP diagnostic sources (linters, etc.) scoped
    -- to the old workspace should also go.
    pcall(vim.diagnostic.reset)

    -- 5. Drop buffers that don't belong in the new cwd (terminals + foreign
    --    files). Persistent-terminal-marked buffers are kept. Iterates by
    --    `buflisted OR loaded` so that listed-but-unloaded buffers from a
    --    previous restore (the ones we `:badd`'d under the old cwd) also get
    --    cleaned up — otherwise they'd pile up across repeated switches.
    local cwd = safe_getcwd()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local persist = vim.b[buf].luanphan_persist_term
      local relevant = vim.bo[buf].buflisted or vim.api.nvim_buf_is_loaded(buf)
      if relevant and not persist then
        local name = vim.api.nvim_buf_get_name(buf)
        local buftype = vim.bo[buf].buftype
        if buftype == "terminal" and not vim.startswith(name, "term://" .. cwd) then
          -- Non-agent terminals are always "modified" (live process); force-close.
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        elseif buftype == "" and name ~= "" and not vim.bo[buf].modified and not path_is_in_dir(name, cwd) then
          pcall(vim.api.nvim_buf_delete, buf, { force = false })
        end
      end
    end

    -- 6. Restore the buffer list saved for the NEW cwd (if we've been here
    --    before this session). `:badd` only adds to the buffer list (loaded
    --    on demand), so it's cheap; LSP attaches when the user actually
    --    enters one of them. The previously-active file (if any) gets
    --    `:edit`ed into a non-tree editor window so the user lands directly
    --    on what they were last looking at.
    local restored, reopened = restore_buffers(cwd)

    -- 7. Restore this repository's backward jump history. Neovim has no
    --    jumplist setter, so each saved location is replayed as a native jump.
    restore_jumplist(cwd, reopened)

    -- 8. Re-attach LSP for every currently-loaded buffer in the new cwd by
    --    re-firing FileType. Picks up the buffer that's still on screen
    --    (whichever one survived the cleanup) so diagnostics/code-actions
    --    work immediately, without waiting for the user to BufEnter.
    refire_filetype_all()

    -- 9. Re-open nvim-tree if it was open before. Pass the new cwd as the
    --    open path AND follow up with `change_root` — the tree caches its
    --    last root across close/open cycles, so without the explicit path
    --    it would re-open rooted at the previous worktree (the "stuck at
    --    one repo" bug). `change_root` covers the case where a nvim-tree
    --    version ignores the `path` arg.
    if ok_tree then
      if tree_was_open then
        pcall(tree_api.tree.open, { path = cwd, focus = false })
      end
      pcall(tree_api.tree.change_root, cwd)
    end

    -- 10. Focus priority: agent float > reopened active file > nvim-tree.
    focus_after_switch(reopened)

    local msg = "Switched to " .. (kind or "worktree") .. ": " .. path
    if restored > 0 then
      msg = msg .. string.format(" (restored %d buffer%s)", restored, restored == 1 and "" or "s")
    end
    if reopened then
      msg = msg .. " — reopened " .. vim.fn.fnamemodify(reopened, ":~:.")
    end
    vim.notify(msg, vim.log.levels.INFO)
  end

  local function telescope_modules()
    local ok_p, pickers = pcall(require, "telescope.pickers")
    local ok_f, finders = pcall(require, "telescope.finders")
    local ok_c, conf = pcall(require, "telescope.config")
    local ok_a, actions = pcall(require, "telescope.actions")
    local ok_s, action_state = pcall(require, "telescope.actions.state")
    if not (ok_p and ok_f and ok_c and ok_a and ok_s) then
      vim.notify("telescope not available", vim.log.levels.ERROR)
      return nil
    end
    return pickers, finders, conf.values, actions, action_state
  end

  local function pick_worktree()
    if rescue_deleted_cwd() then
      return
    end

    local pickers, finders, conf, actions, action_state = telescope_modules()
    if not pickers then return end

    local trees = list_worktrees()
    if #trees == 0 then
      vim.notify("no worktrees found (not a git repo?)", vim.log.levels.WARN)
      return
    end
    local cur = safe_getcwd()
    if cur == "" then
      vim.notify("could not read current cwd", vim.log.levels.ERROR)
      return
    end

    local cur_root = git_root(cur) or cur
    local rel = ""
    if cur ~= cur_root and vim.startswith(cur, cur_root .. "/") then
      rel = cur:sub(#cur_root + 2)
    end

    pickers.new({}, {
      prompt_title = "Git Worktrees",
      finder = finders.new_table({
        results = trees,
        entry_maker = function(tree)
          local ref = tree.branch or (tree.head and ("@" .. tree.head)) or "detached"
          local marker = (tree.path == cur_root) and "* " or "  "
          local display = string.format("%s%-30s %s", marker, ref, tree.path)
          return {
            value = tree,
            display = display,
            ordinal = ref .. " " .. tree.path,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, _map)
        actions.select_default:replace(function()
          local sel = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if not sel or not sel.value or not sel.value.path then
            vim.notify("worktree picker: no selection", vim.log.levels.WARN)
            return
          end
          local target = sel.value.path
          if target == cur_root then
            recent_paths.touch(target)
            vim.notify("already in this worktree", vim.log.levels.INFO)
            return
          end
          -- Mirror the sub-path into the new worktree if it exists. Falls back
          -- to the worktree root if the equivalent folder is missing in the
          -- target (e.g. the nested module hasn't been added there yet).
          local final_target = target
          if rel ~= "" then
            local nested = target .. "/" .. rel
            if vim.fn.isdirectory(nested) == 1 then
              final_target = nested
            end
          end
          -- Defer the switch so telescope has fully closed its float/window.
          vim.schedule(function()
            switch_to(final_target, nil, target)
          end)
        end)
        return true
      end,
    }):find()
  end

  local function pick_project()
    if rescue_deleted_cwd() then
      return
    end

    local repos, current_root = list_all_project_repos()
    if #repos == 0 then
      vim.notify("no workspace or root git repositories found", vim.log.levels.WARN)
      return
    end

    local pickers, finders, conf, actions, action_state = telescope_modules()
    if not pickers then return end
    local entries = group_project_entries(repos, current_root)
    local sorter = make_project_sorter(conf.generic_sorter({}), require("telescope.sorters"))
    pickers.new({}, {
      prompt_title = "Git Projects",
      default_selection_index = #entries > 1 and 2 or 1,
      finder = finders.new_table({
        results = entries,
        entry_maker = function(entry)
          return {
            value = entry,
            display = entry.display,
            ordinal = entry.ordinal,
          }
        end,
      }),
      sorter = sorter,
      attach_mappings = function(prompt_bufnr, _map)
        actions.move_selection_next:replace(function(bufnr)
          move_project_selection(action_state.get_current_picker(bufnr), 1)
        end)
        actions.move_selection_previous:replace(function(bufnr)
          move_project_selection(action_state.get_current_picker(bufnr), -1)
        end)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          if not selection or not selection.value then
            vim.notify("project picker: no selection", vim.log.levels.WARN)
            return
          end
          if selection.value.header then
            return
          end
          actions.close(prompt_bufnr)
          if selection.value.path == current_root then
            recent_paths.touch(selection.value.path)
            vim.notify("already in this project", vim.log.levels.INFO)
            return
          end
          vim.schedule(function()
            switch_to(selection.value.path, "project")
          end)
        end)
        return true
      end,
      on_complete = {
        function(picker)
          local selection = picker:get_selection()
          if selection and selection.value and selection.value.header then
            move_project_selection(picker, 1)
          end
        end,
      },
    }):find()
  end

  local function activate_workspace(workspace)
    if workspace.path == safe_getcwd() then
      recent_paths.touch(workspace.path)
      vim.notify("already in this workspace", vim.log.levels.INFO)
      return
    end
    switch_to(workspace.path, "workspace root")
  end

  local function pick_workspace_project()
    if rescue_deleted_cwd() then
      return
    end

    local workspaces = list_workspace_directories()
    if #workspaces == 0 then
      vim.notify("no local workspaces found", vim.log.levels.WARN)
      return
    end

    local pickers, finders, conf, actions, action_state = telescope_modules()
    if not pickers then return end
    local current = safe_getcwd()
    local default_selection = 1
    for index, workspace in ipairs(workspaces) do
      if path_is_in_dir(current, workspace.path) then
        default_selection = index
        break
      end
    end

    pickers.new({}, {
      prompt_title = "Workspaces",
      default_selection_index = default_selection,
      finder = finders.new_table({
        results = workspaces,
        entry_maker = function(workspace)
          local marker = path_is_in_dir(current, workspace.path) and "* " or "  "
          local suffix = workspace.empty and " [no code repo yet]" or ""
          return {
            value = workspace,
            display = marker .. workspace.name .. suffix,
            ordinal = workspace.name,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, _map)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if not selection or not selection.value then
            vim.notify("workspace picker: no selection", vim.log.levels.WARN)
            return
          end
          local workspace = selection.value
          vim.schedule(function()
            activate_workspace(workspace)
          end)
        end)
        return true
      end,
    }):find()
  end

  local function activate_agent(instance)
    if instance.path ~= safe_getcwd() then
      switch_to(instance.path, "agent project")
    else
      recent_paths.touch(instance.path)
    end
    close_other_agent_windows(instance.bufnr)
    local ok, agents = pcall(require, "luanphan.plugins.agents")
    if not ok or type(agents.focus) ~= "function" or not agents.focus(instance.agent, instance.bufnr) then
      vim.notify("could not focus " .. instance.agent .. " agent", vim.log.levels.ERROR)
    end
  end

  local function pick_agent()
    if rescue_deleted_cwd() then
      return
    end

    local instances = list_active_agents()
    if #instances == 0 then
      vim.notify("no active agent terminals found", vim.log.levels.WARN)
      return
    end

    local pickers, finders, conf, actions, action_state = telescope_modules()
    if not pickers then return end
    pickers.new({}, {
      prompt_title = "Active Agents",
      finder = finders.new_table({
        results = instances,
        entry_maker = function(instance)
          return {
            value = instance,
            display = instance.display,
            ordinal = instance.ordinal,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, _map)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if not selection or not selection.value or not selection.value.path then
            vim.notify("agent picker: no selection", vim.log.levels.WARN)
            return
          end
          local instance = selection.value
          vim.schedule(function()
            activate_agent(instance)
          end)
        end)
        return true
      end,
    }):find()
  end

  local function register_keymap()
    pcall(vim.api.nvim_del_user_command, "WorktreeSwitch")
    pcall(vim.api.nvim_del_user_command, "ProjectSwitch")
    pcall(vim.api.nvim_del_user_command, "RepositorySwitch")
    pcall(vim.api.nvim_del_user_command, "AgentSwitch")
    vim.api.nvim_create_user_command("WorktreeSwitch", pick_worktree, {
      desc = "Switch nvim instance to another git worktree",
    })
    vim.api.nvim_create_user_command("ProjectSwitch", pick_workspace_project, {
      desc = "Pick a local workspace and switch to its root",
    })
    vim.api.nvim_create_user_command("RepositorySwitch", pick_project, {
      desc = "Switch nvim instance to an adjacent workspace or root git repository",
    })
    vim.api.nvim_create_user_command("AgentSwitch", pick_agent, {
      desc = "Switch nvim instance to a project with an active agent",
    })
    vim.keymap.set("n", "<leader>ww", pick_worktree, { desc = "Switch workspace" })
    vim.keymap.set("n", "<leader>wr", pick_project, { desc = "Pick repository" })
    vim.keymap.set("n", "<leader>wp", pick_workspace_project, { desc = "Pick workspace" })
    vim.keymap.set("n", "<leader>w;", pick_agent, { desc = "Switch active agent" })
  end

  register_keymap()

  local test_api = {
    switch_to = switch_to,
    pick_worktree = pick_worktree,
    pick_project = pick_project,
    pick_workspace_project = pick_workspace_project,
    pick_agent = pick_agent,
    activate_workspace = activate_workspace,
    activate_agent = activate_agent,
    list_sibling_repos = list_sibling_repos,
    list_worktrees = list_worktrees,
    list_all_project_repos = list_all_project_repos,
    list_workspace_directories = list_workspace_directories,
    group_project_entries = group_project_entries,
    make_project_sorter = make_project_sorter,
    move_project_selection = move_project_selection,
    list_active_agents = list_active_agents,
    refire_filetype_all = refire_filetype_all,
    snapshot = snapshot_buffers,
    restore = restore_buffers,
    rescue_deleted_cwd = rescue_deleted_cwd,
    store_key = BUFSTORE_KEY,
  }
  _G._luanphan_wt_test = test_api
  return test_api
end

local function ensure_setup()
  if not api then
    api = setup()
  end
  return api
end

local function pick_worktree()
  ensure_setup().pick_worktree()
end

local function pick_project()
  ensure_setup().pick_project()
end

local function pick_workspace_project()
  ensure_setup().pick_workspace_project()
end

local function pick_agent()
  ensure_setup().pick_agent()
end

return {
  {
    "luanphan-worktree",
    virtual = true,
    init = init,
    cmd = { "WorktreeSwitch", "ProjectSwitch", "RepositorySwitch", "AgentSwitch" },
    keys = {
      { "<leader>ww", pick_worktree, desc = "Switch workspace" },
      { "<leader>wr", pick_project, desc = "Pick repository" },
      { "<leader>wp", pick_workspace_project, desc = "Pick workspace" },
      { "<leader>w;", pick_agent, desc = "Switch active agent" },
    },
    config = ensure_setup,
  },
}
