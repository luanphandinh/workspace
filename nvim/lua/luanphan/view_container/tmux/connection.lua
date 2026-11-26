-- One tmux control-mode connection, with pane output routed to mirrored panes.
local pty = require("luanphan.view_container.tmux.pane")

local M = {}

-- opts.pane(id) finds the mirrored pane for a tmux pane id. ready, event and exit are passed
-- through; `pause` (sent with the `pause-after` flag) is handled here.
function M.attach(server, session, opts)
  local client
  client = server:attach(session, {
    flags = opts.flags,
    ready = opts.ready,
    output = function(id, bytes) pty.receive(opts.pane(id), bytes) end,
    event = function(name, payload)
      if name == "pause" then
        -- tmux stopped this pane because Neovim fell behind; resume it and repaint from tmux.
        local pane = opts.pane(payload)
        if pane then pane.ready = false end
        client:request({ "refresh-client", "-A", payload .. ":continue" }, function(ok)
          if ok and pane then pty.paint(pane, opts.can_paint) end
        end)
      elseif opts.event then
        opts.event(name, payload)
      end
    end,
    exit = opts.exit,
  })
  return client
end

return M
