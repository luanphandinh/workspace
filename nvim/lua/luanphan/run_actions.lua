local M = {}

function M.config_path()
  return vim.g.luanphan_run_actions_path
    or (vim.fn.stdpath("data") .. "/run-actions.json")
end

local function default_lines()
  return {
    "[",
    "  {",
    '    "name": "Run current Python file",',
    '    "cmd": "python3",',
    '    "args": ["{{FILE_NAME}}"]',
    "  }",
    "]",
  }
end

function M.ensure_config(path)
  path = path or M.config_path()
  if vim.fn.filereadable(path) == 1 then
    return path
  end

  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ok, err = pcall(vim.fn.writefile, default_lines(), path)
  if not ok then
    vim.notify("Could not create run actions: " .. tostring(err), vim.log.levels.ERROR)
  end
  return path
end

local function invalid(message)
  vim.notify("Invalid run actions: " .. message, vim.log.levels.ERROR)
end

function M.read(path)
  path = M.ensure_config(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    invalid(tostring(lines))
    return nil
  end

  local decoded
  ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok or type(decoded) ~= "table" then
    invalid(ok and "expected a JSON object or array" or tostring(decoded))
    return nil
  end
  if decoded.name ~= nil then
    decoded = { decoded }
  elseif not vim.islist(decoded) then
    invalid("expected a JSON object or array")
    return nil
  end

  for index, action in ipairs(decoded) do
    if type(action) ~= "table"
        or type(action.name) ~= "string" or action.name == ""
        or type(action.cmd) ~= "string" or action.cmd == ""
        or (action.args ~= nil and not vim.islist(action.args)) then
      invalid("action " .. index .. " requires name, cmd, and an args array")
      return nil
    end
    action.args = action.args or {}
    for _, arg in ipairs(action.args) do
      if type(arg) ~= "string" then
        invalid("action " .. index .. " args must contain only strings")
        return nil
      end
    end
  end
  return decoded
end

local function expand_args(args)
  local file_name = vim.api.nvim_buf_get_name(0)
  local expanded = {}
  for _, arg in ipairs(args) do
    if arg:find("{{FILE_NAME}}", 1, true) then
      if file_name == "" then
        vim.notify("Current buffer has no file name", vim.log.levels.ERROR)
        return nil
      end
      arg = arg:gsub("{{FILE_NAME}}", function()
        return file_name
      end)
    end
    local unknown = arg:match("{{([%w_]+)}}")
    if unknown then
      vim.notify("Unknown run action variable: " .. unknown, vim.log.levels.ERROR)
      return nil
    end
    expanded[#expanded + 1] = arg
  end
  return expanded
end

function M.run(action)
  local args = expand_args(action.args or {})
  if not args then
    return
  end

  local escaped = { vim.fn.shellescape(action.cmd) }
  for _, arg in ipairs(args) do
    escaped[#escaped + 1] = vim.fn.shellescape(arg)
  end
  local shell_command = table.concat(escaped, " ")
  local command = string.format(
    "printf '%%s\\n\\n' %s && %s",
    vim.fn.shellescape("$ " .. shell_command),
    shell_command
  )
  require("luanphan.terminal").run_command(command, vim.fn.getcwd(), action.name)
end

function M.pick()
  local configured = M.read()
  if not configured or #configured == 0 then
    vim.notify("No run actions configured", vim.log.levels.WARN)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers.new({}, {
    prompt_title = "Run Action",
    layout_strategy = "center",
    layout_config = { width = 0.3, height = 0.25 },
    finder = finders.new_table({
      results = configured,
      entry_maker = function(action)
        return { value = action, display = action.name, ordinal = action.name }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if selection then
          M.run(selection.value)
        end
      end)
      return true
    end,
  }):find()
end

function M.open_editor()
  require("luanphan.settings_editor").open(M.ensure_config(), {
    title = "Run Actions",
    filetype = "json",
  })
end

return M
