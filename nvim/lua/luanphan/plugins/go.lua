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

---Resolve the current buffer's Go import path and package directory.
---@return string|nil import_path
---@return string|nil package_dir
function M.get_current_import_path()
  local file_dir = vim.fn.expand('%:p:h')
  if file_dir == "" then return nil end
  local cmd = string.format(
    "cd %s && go list -f '{{.ImportPath}}' . 2>/dev/null",
    vim.fn.shellescape(file_dir)
  )
  local handle = io.popen(cmd)
  if not handle then return nil end
  local result = handle:read("*a"):gsub("%s+$", "")
  handle:close()
  if result == "" then return nil end
  -- Defensive: if somehow multiple lines slipped through, take the first.
  return vim.split(result, "\n", { plain = true })[1], file_dir
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

---Run the command in a persistent workspace terminal tab.
---@param shell_cmd string full shell command (passed to &shell like |:terminal|)
---@param cwd string directory containing the tested Go package
local function run_in_test_terminal(shell_cmd, cwd)
  local line = "$ " .. shell_cmd
  local full = string.format("printf '%%s\\n\\n' %s && %s", vim.fn.shellescape(line), shell_cmd)
  require("luanphan.terminal").run_command(full, cwd, "Go test")
end

---Run the Go test / example function name under (or above) the cursor.
function M.run_go_test_at_cursor()
  local test_name = M.get_test_name()
  if test_name == "" then
    vim.notify("No test function found near cursor", vim.log.levels.WARN)
    return
  end

  local import_path, package_dir = M.get_current_import_path()
  if not import_path then
    vim.notify("Could not resolve import path (is `go list` valid here?)", vim.log.levels.ERROR)
    return
  end

  local cmd = string.format(
    "%s test -timeout 30s -run ^%s$ %s -count=1 -v",
    vim.fn.shellescape(go_bin()),
    test_name,
    import_path
  )

  run_in_test_terminal(cmd, package_dir)
end

local function run_go_tests(timeout, package_suffix)
  local import_path, package_dir = M.get_current_import_path()
  if not import_path then
    vim.notify("Could not resolve import path (is `go list` valid here?)", vim.log.levels.ERROR)
    return
  end

  local cmd = string.format(
    "%s test -timeout %ds %s%s -count=1 -v",
    vim.fn.shellescape(go_bin()),
    timeout,
    import_path,
    package_suffix
  )

  run_in_test_terminal(cmd, package_dir)
end

---Run all tests in the current package.
function M.run_go_test_file()
  run_go_tests(30, "")
end

---Run all tests in the current package and its subpackages.
function M.run_go_test_package()
  run_go_tests(60, "/...")
end

return M
