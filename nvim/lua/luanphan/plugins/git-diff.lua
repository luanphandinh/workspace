return function(use)
  -- Global git diff viewer
  use {
    "sindrets/diffview.nvim",
    requires = "nvim-lua/plenary.nvim",
    config = function()
      local actions = require("diffview.actions")
      local diffview = require("diffview")

      -- Find existing diffview tab
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

      -- Toggle/focus diffview
      local function toggle_diffview()
        -- Check if current tab is diffview
        local cur_buf = vim.api.nvim_buf_get_name(0)
        if cur_buf:match("^diffview://") then
          vim.cmd("DiffviewClose")
          return
        end

        -- Check if diffview tab exists
        local existing_tab = find_diffview_tab()
        if existing_tab then
          vim.api.nvim_set_current_tabpage(existing_tab)
          return
        end

        -- Open new diffview
        vim.cmd("DiffviewOpen")
      end

      -- Toggle file history for current file
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

      -- Toggle file history for all files
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

      -- Diff current branch with base branch (main or master)
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

        -- Find base branch (main, master, or develop)
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

      require("diffview").setup({
        view = {
          default = {
            layout = "diff2_horizontal",
            winbar_info = true,
          },
        },
        file_panel = {
          win_config = {
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

      -- Git diff globally
      vim.keymap.set("n", "<leader>gd", toggle_diffview, { desc = "Git diff (current changes)" })
      vim.keymap.set("n", "<leader>gD", toggle_branch_diff, { desc = "Git diff branch (vs base)" })
      vim.keymap.set("n", "<leader>gH", toggle_file_history, { desc = "File history (current)" })
      vim.keymap.set("n", "<leader>gA", toggle_all_file_history, { desc = "File history (all)" })
    end,
  }

  -- Git conflict navigation and resolution
  use {
    "akinsho/git-conflict.nvim",
    tag = "*",
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
  }
end
