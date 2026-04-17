local M = {}

---Get the Go test / example function name under (or above) the cursor.
---@return string fname The test function name (e.g. "TestFoo") or '' if none.
function M.get_test_name()
  -- Search **backwards**, accept match at cursor, don't move cursor, no wrap.
  local lnum = vim.fn.search([[func \(Test\|Example\)]], 'bcnW')
  if lnum == 0 then
    return ''
  end

  -- Grab the declaration line.
  local decl = vim.fn.getline(lnum)

  -- Extract the identifier after `func` and before `(`
  -- e.g. "func TestFoo(t *testing.T)"  ->  "TestFoo"
  local name = decl:match('%s*func%s+([%w_]+)%s*%(') or ''

  return name
end

function M.get_go_mod_name()
  local handle = io.popen("go list -m")
  if not handle then return nil end
  local result = handle:read("*a"):gsub("%s+$", "")
  handle:close()
  return result
end

function M.get_relative_path()
  local file_path = vim.fn.expand('%:p:h')
  local rel_path = vim.fn.fnamemodify(file_path, ":."):gsub("^./", "")
  return rel_path
end

---@return string
local function go_bin()
  local p = vim.fn.exepath("go")
  if p ~= "" then
    return p
  end
  if vim.fn.executable("/usr/local/go/bin/go") == 1 then
    return "/usr/local/go/bin/go"
  end
  return "go"
end

--- Open a vertical split and run {shell_cmd} in a |jobstart({ term = true })| terminal.
--- |jobstart| with |term| attaches to the *current* buffer — after |:vsplit| that is still the editor
--- buffer unless we use |:enew|, so without |enew| the Go file buffer would be replaced (looks "blank").
--- Prints the exact command in the terminal first, then runs it.
---@param shell_cmd string full shell command (passed to &shell like |:terminal|)
local function run_in_test_terminal(shell_cmd)
  vim.cmd("rightbelow vsplit | enew")
  local line = "$ " .. shell_cmd
  local full = string.format("printf '%%s\\n\\n' %s && %s", vim.fn.shellescape(line), shell_cmd)
  local jid = vim.fn.jobstart(full, { term = true })
  if jid == 0 or jid == -1 then
    vim.notify("Failed to start test in terminal", vim.log.levels.ERROR)
    return
  end
  -- Insert mode is entered by the TermOpen autocommand in |terminal.lua|.
end

---Run the Go test / example function name under (or above) the cursor.
function M.run_go_test_at_cursor()
  local test_name = M.get_test_name()
  if test_name == "" then
    vim.notify("No test function found near cursor", vim.log.levels.WARN)
    return
  end

  local mod_name = M.get_go_mod_name()
  if not mod_name or mod_name == "" then
    vim.notify("Could not resolve module (is `go list -m` valid here?)", vim.log.levels.ERROR)
    return
  end

  local rel_path = M.get_relative_path()
  local cmd = string.format(
    "%s test -timeout 30s -run ^%s$ %s/%s -count=1 -v",
    vim.fn.shellescape(go_bin()),
    test_name,
    mod_name,
    rel_path
  )

  run_in_test_terminal(cmd)
end

---Run all tests in the current file.
function M.run_go_test_file()
  local mod_name = M.get_go_mod_name()
  if not mod_name or mod_name == "" then
    vim.notify("Could not resolve module (is `go list -m` valid here?)", vim.log.levels.ERROR)
    return
  end

  local rel_path = M.get_relative_path()

  local cmd = string.format(
    "%s test -timeout 30s %s/%s -count=1 -v",
    vim.fn.shellescape(go_bin()),
    mod_name,
    rel_path
  )

  run_in_test_terminal(cmd)
end

---Run all tests in the current package.
function M.run_go_test_package()
  local mod_name = M.get_go_mod_name()
  if not mod_name or mod_name == "" then
    vim.notify("Could not resolve module (is `go list -m` valid here?)", vim.log.levels.ERROR)
    return
  end

  local rel_path = M.get_relative_path()

  local cmd = string.format(
    "%s test -timeout 60s %s/%s -count=1 -v ./...",
    vim.fn.shellescape(go_bin()),
    mod_name,
    rel_path
  )

  run_in_test_terminal(cmd)
end

-- lua/telescope_subtests.lua
function M.go_subtests_picker()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "go" then
    vim.notify("Not a Go file", vim.log.levels.WARN)
    return
  end

  -- ── 1. Parse file with Tree‑sitter and collect sub‑tests ───────────────
  local query   = vim.treesitter.query.parse("go", [[
    (call_expression
       function: (selector_expression
                   field: (field_identifier) @fname (#eq? @fname "Run"))
       arguments: (argument_list
                    (interpreted_string_literal) @name))
  ]])

  local root    = vim.treesitter.get_parser(bufnr, "go"):parse()[1]:root()
  local results = {}
  for id, node in query:iter_captures(root, bufnr, 0, -1) do
    if query.captures[id] == "name" then
      local txt      = vim.treesitter.get_node_text(node, bufnr):gsub('"', "")
      local row, col = node:start()
      table.insert(results, {
        display  = txt,
        ordinal  = txt,
        filename = vim.api.nvim_buf_get_name(bufnr),
        lnum     = row + 1,
        col      = col + 1,
      })
    end
  end
  if #results == 0 then
    vim.notify("No t.Run sub‑tests found", vim.log.levels.INFO)
    return
  end

  -- ── 2. Show a small centred Telescope picker ───────────────────────────
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf    = require("telescope.config").values
  local themes  = require("telescope.themes")
  local make    = require("telescope.make_entry")

  pickers.new(themes.get_dropdown({
    prompt_title = "Sub‑tests",
    previewer    = false,
    width        = 0.4,
    height       = 0.3,
  }), {
    finder = finders.new_table({
      results     = results,
      entry_maker = function(entry)
        return {
          value = entry,
          display = entry.display,
          ordinal = entry.ordinal,
          lnum = entry.lnum,
          col = entry.col,
          filename = entry.filename,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
  }):find()
end

return M
