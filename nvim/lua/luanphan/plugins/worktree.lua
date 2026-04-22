return function(_use)
  -- Pure telescope + git CLI; no external plugin.
  -- Requires are deferred into the function so module load doesn't touch
  -- telescope (which is lazy-loaded by packer).

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
    vim.cmd("cd " .. vim.fn.fnameescape(path))

    for _, client in pairs(vim.lsp.get_clients()) do
      client:stop()
    end

    local cwd = vim.fn.getcwd()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        local name = vim.api.nvim_buf_get_name(buf)
        local modified = vim.bo[buf].modified
        if name ~= "" and not modified and not vim.startswith(name, cwd) then
          pcall(vim.api.nvim_buf_delete, buf, { force = false })
        end
      end
    end

    vim.notify("Switched to worktree: " .. path, vim.log.levels.INFO)
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
end
