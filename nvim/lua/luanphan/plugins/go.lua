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

return M
