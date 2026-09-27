local M = {}

function M.setup()
  if not vim.env.SSH_TTY and not vim.env.SSH_CONNECTION then
    return
  end

  local tmux_copy = vim.fn.expand("~/bin/tmux-copy-osc52")
  if vim.env.TMUX and vim.fn.executable(tmux_copy) == 1 then
    vim.g.clipboard = {
      name = "OSC52 through tmux client",
      copy = {
        ["+"] = { tmux_copy },
        ["*"] = { tmux_copy },
      },
      paste = {
        ["+"] = { "tmux", "save-buffer", "-" },
        ["*"] = { "tmux", "save-buffer", "-" },
      },
      cache_enabled = 0,
    }
  else
    vim.g.clipboard = "osc52"
  end
end

return M
