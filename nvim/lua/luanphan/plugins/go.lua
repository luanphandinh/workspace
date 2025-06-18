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
  local cwd = vim.fn.getcwd()
  local file_path = vim.fn.expand('%:p:h')
  local rel_path = vim.fn.fnamemodify(file_path, ":."):gsub("^./", "")
  return rel_path
end

---Run the Go test / example function name under (or above) the cursor.
function M.run_go_test_at_cursor()
  local test_name = M.get_test_name()
  local mod_name = M.get_go_mod_name()
  local rel_path = M.get_relative_path()

  if not test_name then
    print("No test function found")
  end

  -- local test_dir = vim.fn.expand("%:p:h") -- directory of current file
  local cmd = string.format(
    "/usr/local/go/bin/go test -timeout 30s -run ^%s$ %s/%s -gcflags=all=-N -gcflags=all=-l -count=1 -v",
    test_name,
    mod_name,
    rel_path
  )

  vim.cmd("vsplit | terminal " .. cmd)
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
