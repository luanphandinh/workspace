return function(use)
  -- Toggleable terminal, scoped per worktree (cwd). Switching worktrees hides the
  -- current terminal; toggling again in a new cwd spawns a fresh one; switching
  -- back re-shows the previous one.
  use {
    "akinsho/toggleterm.nvim",
    config = function()
      require("toggleterm").setup({
        size = 100,
        direction = "vertical", -- opens on the right
        shade_terminals = false,
        persist_size = true,
        persist_mode = false,
        -- Keep the pane after the shell job exits so output stays visible (scroll with Esc then j/k).
        close_on_exit = false,
        auto_scroll = true,
      })

      local Terminal = require("toggleterm.terminal").Terminal
      local terms = {} -- cwd -> Terminal (per-worktree persistent buffer)

      local function get_term()
        local cwd = vim.fn.getcwd()
        local t = terms[cwd]
        if t and t.bufnr and vim.api.nvim_buf_is_valid(t.bufnr) then
          return t
        end
        t = Terminal:new({
          dir = cwd,
          direction = "vertical",
          close_on_exit = false,
          on_open = function(term)
            pcall(function() vim.b[term.bufnr].luanphan_persist_term = true end)
          end,
        })
        terms[cwd] = t
        return t
      end

      vim.keymap.set("n", "<leader>tt", function()
        get_term():toggle()
      end, { desc = "Toggle terminal" })

      -- On any cwd change, just hide the current worktree's terminal window.
      -- The buffer is preserved in `terms[cwd]` so toggling back on return
      -- resumes the same shell; we do NOT auto-reopen — user toggles manually.
      local function hide_current()
        local cwd = vim.fn.getcwd()
        local t = terms[cwd]
        if t and t.bufnr and vim.api.nvim_buf_is_valid(t.bufnr) and t:is_open() then
          t:close()
        end
      end

      vim.api.nvim_create_autocmd("User", {
        pattern = "LuanphanWorktreeSwitchPre",
        group = vim.api.nvim_create_augroup("LuanphanToggletermWorktreePre", { clear = true }),
        callback = hide_current,
      })

      vim.api.nvim_create_autocmd("DirChangedPre", {
        group = vim.api.nvim_create_augroup("LuanphanToggletermDirPre", { clear = true }),
        callback = hide_current,
      })

      -- Terminal mode mappings
      function _G.set_terminal_keymaps()
        local opts = { buffer = 0 }
        vim.keymap.set("t", "<esc>", [[<c-\><c-n>]], opts)
      end

      -- Enter terminal mode only when a terminal buffer is first created — not on every BufEnter.
      -- Otherwise each refocus runs |startinsert|, so j/k go to a dead PTY after `go test` exits instead
      -- of moving in normal mode in the scrollback.
      vim.api.nvim_create_autocmd("TermOpen", {
        pattern = "term://*",
        callback = function()
          vim.defer_fn(function()
            if vim.bo.buftype == "terminal" then
              vim.cmd("startinsert")
            end
          end, 10)
        end,
      })

      vim.cmd("autocmd! TermOpen * lua set_terminal_keymaps()")
    end,
  }
end
