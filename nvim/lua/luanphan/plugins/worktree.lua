return function(_use)
  -- Pure telescope + git CLI; no external plugin.
  -- Requires are deferred into the function so module load doesn't touch
  -- telescope (which is lazy-loaded by packer).

  -- Per-cwd buffer state. In-memory only (vim.g key) so it survives the
  -- switch but not an nvim restart. Map shape:
  --   { [cwd] = {
  --       files     = { abs_paths… },
  --       positions = { [abs_path] = { line, col }, … },  -- per-file cursor
  --       active    = abs_path|nil,
  --     } }
  local BUFSTORE_KEY = "luanphan_workspace_buffers"

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
    -- [No Name] / tree / picker buffer when pressing <leader>gw, fall back
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
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      local bt = vim.bo[buf].buftype
      local ft = vim.bo[buf].filetype
      if bt == "" and ft ~= "NvimTree" then
        return win
      end
    end
    return nil
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
        pcall(vim.api.nvim_exec_autocmds, "FileType", { buffer = buf })
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
    return trees
  end

  local function switch_to(path)
    if vim.fn.isdirectory(path) == 0 then
      vim.notify("worktree path not found: " .. path, vim.log.levels.ERROR)
      return
    end

    -- 1. Snapshot the OLD cwd's open file list before we touch anything else.
    --    Lets us restore the same buffer list when the user returns later.
    local old_cwd = vim.fn.getcwd()
    snapshot_buffers(old_cwd)

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

    -- 2b. Toggle off the <leader>tt terminal (terminal.lua listens for this
    --     User event) so the cd doesn't have to race with a visible window.
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "LuanphanWorktreeSwitchPre" })

    -- 3. cd. Fires DirChangedPre/DirChanged for the persistent-terminal modules.
    vim.cmd("cd " .. vim.fn.fnameescape(path))

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
    local cwd = vim.fn.getcwd()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local persist = vim.b[buf].luanphan_persist_term
      local relevant = vim.bo[buf].buflisted or vim.api.nvim_buf_is_loaded(buf)
      if relevant and not persist then
        local name = vim.api.nvim_buf_get_name(buf)
        local buftype = vim.bo[buf].buftype
        if buftype == "terminal" and not vim.startswith(name, "term://" .. cwd) then
          -- Non-agent terminals are always "modified" (live process); force-close.
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        elseif buftype == "" and name ~= "" and not vim.bo[buf].modified and not vim.startswith(name, cwd) then
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

    -- 7. Re-attach LSP for every currently-loaded buffer in the new cwd by
    --    re-firing FileType. Picks up the buffer that's still on screen
    --    (whichever one survived the cleanup) so diagnostics/code-actions
    --    work immediately, without waiting for the user to BufEnter.
    refire_filetype_all()

    -- 8. Re-open nvim-tree if it was open before. Pass the new cwd as the
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

    local msg = "Switched to worktree: " .. path
    if restored > 0 then
      msg = msg .. string.format(" (restored %d buffer%s)", restored, restored == 1 and "" or "s")
    end
    if reopened then
      msg = msg .. " — reopened " .. vim.fn.fnamemodify(reopened, ":~:.")
    end
    vim.notify(msg, vim.log.levels.INFO)
  end

  local function pick_worktree()
    local ok_p, pickers = pcall(require, "telescope.pickers")
    local ok_f, finders = pcall(require, "telescope.finders")
    local ok_c, conf = pcall(require, "telescope.config")
    local ok_a, actions = pcall(require, "telescope.actions")
    local ok_s, action_state = pcall(require, "telescope.actions.state")
    if not (ok_p and ok_f and ok_c and ok_a and ok_s) then
      vim.notify("telescope not available", vim.log.levels.ERROR)
      return
    end

    local trees = list_worktrees()
    if #trees == 0 then
      vim.notify("no worktrees found (not a git repo?)", vim.log.levels.WARN)
      return
    end
    local cur = vim.fn.getcwd()

    pickers.new({}, {
      prompt_title = "Git Worktrees",
      finder = finders.new_table({
        results = trees,
        entry_maker = function(tree)
          local ref = tree.branch or (tree.head and ("@" .. tree.head)) or "detached"
          local marker = (tree.path == cur) and "* " or "  "
          local display = string.format("%s%-30s %s", marker, ref, tree.path)
          return {
            value = tree,
            display = display,
            ordinal = ref .. " " .. tree.path,
          }
        end,
      }),
      sorter = conf.values.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, _map)
        actions.select_default:replace(function()
          local sel = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if not sel or not sel.value or not sel.value.path then
            vim.notify("worktree picker: no selection", vim.log.levels.WARN)
            return
          end
          local target = sel.value.path
          if target == cur then
            vim.notify("already in this worktree", vim.log.levels.INFO)
            return
          end
          -- Defer the switch so telescope has fully closed its float/window.
          vim.schedule(function()
            switch_to(target)
          end)
        end)
        return true
      end,
    }):find()
  end

  local function register_keymap()
    vim.api.nvim_create_user_command("WorktreeSwitch", pick_worktree, {
      desc = "Switch nvim instance to another git worktree",
    })
    vim.keymap.set("n", "<leader>gw", pick_worktree, { desc = "Git worktree switch" })
  end

  -- Register at VimEnter so which-key (loaded on VimEnter) sees the mapping.
  -- Also register immediately in case VimEnter has already fired.
  register_keymap()
  vim.api.nvim_create_autocmd("VimEnter", {
    callback = register_keymap,
    once = true,
  })

  -- Test handles. Internal API; not for production use. The headless smoke
  -- test in this repo drives switch_to / snapshot / restore through this.
  _G._luanphan_wt_test = {
    switch_to = switch_to,
    snapshot = snapshot_buffers,
    restore = restore_buffers,
    store_key = BUFSTORE_KEY,
  }
end
