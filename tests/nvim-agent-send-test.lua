-- Run with: nvim --headless -u NONE '+luafile tests/nvim-agent-send-test.lua'
vim.opt.runtimepath:prepend(vim.fn.getcwd() .. "/nvim")

local temp = vim.fn.tempname()
vim.fn.mkdir(temp, "p")
local old_cwd = vim.fn.getcwd()
vim.fn.chdir(temp)
local received = temp .. "/received"
local ready = temp .. "/ready"
local source_win = vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_name(0, temp .. "/example.txt")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "first line", "second line" })
vim.cmd("vsplit | enew")
local terminal = vim.api.nvim_get_current_buf()
local job = vim.fn.termopen({ "python3", "-c", [[
import os, sys, tty
tty.setraw(0)
os.write(1, b"\x1b[?2004h")
with open(sys.argv[1], "wb", buffering=0) as output:
    open(sys.argv[2], "w").close()
    while True:
        output.write(os.read(0, 4096))
]], received, ready })

local cases = {
  { mode = "lines_only", select = false },
  { mode = "lines_only", select = true },
  { mode = "full", select = false },
  { mode = "full", select = true },
}
local expected = ""
local done, failure = false, nil

local function read_received()
  local file = assert(io.open(received, "rb"))
  local bytes = file:read("*a")
  file:close()
  return bytes
end

local function check(fn)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then
    failure, done = err, true
  end
end

local function run_case(index)
  check(function()
    local case = cases[index]
    if not case then
      done = true
      return
    end
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(source_win)
    vim.cmd.normal({ args = { "ggVj" .. vim.keycode("<Esc>") }, bang = true })
    vim.cmd.normal({ args = { "ggVj" .. (case.select and vim.keycode("<C-g>") or "") }, bang = true })
    assert(vim.fn.mode() == (case.select and "S" or "V"), "selection mode not entered: " .. vim.fn.mode())
    local agent = require("luanphan.terminal_agent").create({ defaults = { send_mode = case.mode } })
    agent.send_selection(terminal)
    local payload = "@example.txt:1-2"
    if case.mode == "full" then
      payload = payload .. "\n\nfirst line\nsecond line\n"
    end
    expected = expected .. "\27[200~" .. payload .. "\27[201~"
    -- Return to Neovim's input loop so queued keys reach the terminal too.
    vim.defer_fn(function()
      check(function()
        local actual = read_received()
        assert(actual == expected, "unexpected terminal input: " .. vim.inspect(actual))
        assert(vim.fn.jobwait({ job }, 0)[1] == -1, "terminal process stopped")
        print("PASS " .. case.mode .. (case.select and " select" or " visual"))
        vim.cmd("stopinsert")
        vim.defer_fn(function() run_case(index + 1) end, 20)
      end)
    end, 150)
  end)
end

assert(vim.wait(3000, function() return vim.fn.filereadable(ready) == 1 end), "terminal not ready")
vim.schedule(function() run_case(1) end)
-- Let the real input loop run between sends, including terminal-insert mode.
local timer = vim.uv.new_timer()
timer:start(10, 10, vim.schedule_wrap(function()
  if done then
    timer:stop()
    timer:close()
    vim.cmd("stopinsert")
    vim.fn.jobstop(job)
    vim.fn.chdir(old_cwd)
    vim.fn.delete(temp, "rf")
    if failure then
      io.stderr:write(failure .. "\n")
      vim.cmd("cquit")
    else
      vim.cmd("qa!")
    end
  end
end))
vim.defer_fn(function()
  failure, done = "send test timed out", true
end, 5000)
