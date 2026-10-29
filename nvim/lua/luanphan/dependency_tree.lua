local M = {}

local uv = vim.uv or vim.loop
local width = 40

local function normalize(path)
  if not path or path == "" then
    return nil
  end

  local absolute = vim.fn.fnamemodify(path, ":p")
  local resolved = uv.fs_realpath(absolute) or vim.fs.normalize(absolute)
  if resolved ~= "/" then
    resolved = resolved:gsub("/+$", "")
  end
  return resolved
end

local function is_within(path, root)
  if root == "/" then
    return path:sub(1, 1) == "/"
  end
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function dependency_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.w[win].luanphan_dependency_tree then
      return win, vim.api.nvim_win_get_buf(win)
    end
  end
end

local function editor_file()
  local function from_window(win)
    if not win or not vim.api.nvim_win_is_valid(win) then
      return nil
    end
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype ~= "" then
      return nil
    end
    local file = normalize(vim.api.nvim_buf_get_name(buf))
    if not file or vim.fn.filereadable(file) ~= 1 then
      return nil
    end
    return file, win, buf
  end

  local current = vim.api.nvim_get_current_win()
  local file, win, buf = from_window(current)
  if file then
    return file, win, buf
  end

  local previous = vim.fn.win_getid(vim.fn.winnr("#"))
  file, win, buf = from_window(previous)
  if file then
    return file, win, buf
  end

  for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    file, win, buf = from_window(candidate)
    if file then
      return file, win, buf
    end
  end
end

local function open_selected_dependency(win)
  local selected = vim.fn["netrw#Call"]("NetrwGetWord")
  local path = normalize(vim.fn["netrw#Call"]("NetrwBrowseChgDir", 1, selected, 1, 1))
  if not path then
    return
  end

  if vim.fn.isdirectory(path) == 1 then
    vim.fn["netrw#LocalBrowseCheck"](path)
    return
  end

  local editor_win = vim.w[win].luanphan_dependency_editor_win
  if not editor_win or not vim.api.nvim_win_is_valid(editor_win) then
    return
  end

  local ok, err = pcall(vim.api.nvim_win_call, editor_win, function()
    vim.cmd("silent keepalt edit " .. vim.fn.fnameescape(path))
  end)
  if ok then
    vim.api.nvim_set_current_win(editor_win)
  else
    vim.notify(err, vim.log.levels.ERROR)
  end
end

local function configure_dependency_buffer(win, buf)
  vim.b[buf].luanphan_dependency_tree = true
  vim.bo[buf].bufhidden = "wipe"
  for _, key in ipairs({ "<CR>", "<2-LeftMouse>", "o" }) do
    vim.keymap.set("n", key, function()
      open_selected_dependency(win)
    end, { buffer = buf, silent = true })
  end
end

local function focus_dependency_file(win, buf, file)
  local name = vim.fn.fnamemodify(file, ":t")
  for line, text in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if text:find(name, 1, true) then
      vim.api.nvim_win_set_cursor(win, { line, 0 })
      vim.api.nvim_win_call(win, function()
        vim.cmd("normal! zz")
      end)
      return
    end
  end
end

local function open_dependency_tree(file, editor_win)
  local root = normalize(vim.fn.fnamemodify(file, ":h"))
  if not root then
    return
  end

  editor_win = editor_win or vim.api.nvim_get_current_win()
  local win, buf = dependency_window()
  if not win then
    vim.cmd("botright vnew")
    win = vim.api.nvim_get_current_win()
  else
    vim.api.nvim_set_current_win(win)
  end

  vim.w[win].luanphan_dependency_tree = true
  vim.w[win].luanphan_dependency_editor_win = editor_win
  if not buf or normalize(vim.w[win].luanphan_dependency_root) ~= root then
    vim.cmd("silent noautocmd keepalt Explore " .. vim.fn.fnameescape(root))
    buf = vim.api.nvim_get_current_buf()
    vim.w[win].luanphan_dependency_root = root
  end
  configure_dependency_buffer(win, buf)

  vim.cmd("wincmd L")
  vim.wo.winfixwidth = true
  vim.api.nvim_win_set_width(0, width)
  focus_dependency_file(win, buf, file)
end

local function filter_enabled(name)
  local ok, core = pcall(require, "nvim-tree.core")
  local explorer = ok and core.get_explorer() or nil
  return explorer and explorer.filters and explorer.filters.state[name] == true
end

local function has_dot_component(file, root)
  if not root or not is_within(file, root) then
    return false
  end
  for component in file:sub(#root + 2):gmatch("[^/]+") do
    if component:sub(1, 1) == "." then
      return true
    end
  end
  return false
end

local function is_git_ignored(file)
  local root = vim.fs.root(file, ".git")
  if not root then
    return false
  end
  local result = vim
    .system({ "git", "-C", root, "check-ignore", "-q", "--", file }, { text = true })
    :wait()
  return result.code == 0
end

local function selected_file(tree_api, file)
  local node = tree_api.tree.get_node_under_cursor()
  return node and normalize(node.absolute_path) == file
end

local function focus_workspace_file(tree_api, file, buf, workspace)
  local opts = { buf = buf, open = true, focus = true, update_root = true }
  tree_api.tree.find_file(opts)
  if selected_file(tree_api, file) then
    return
  end

  tree_api.tree.reload()
  tree_api.tree.find_file(opts)
  if selected_file(tree_api, file) then
    return
  end

  local revealed = false
  if has_dot_component(file, workspace) and filter_enabled("dotfiles") then
    tree_api.filter.dotfiles.toggle()
    vim.g.luanphan_show_dotfiles = 1
    revealed = true
  end
  if is_git_ignored(file) and filter_enabled("git_ignored") then
    require("luanphan.actions").set_gitignore_visible(true)
    revealed = true
  end
  if revealed then
    tree_api.tree.find_file(opts)
  end
end

function M.focus(tree_api)
  local current_win = vim.api.nvim_get_current_win()
  local current_buf = vim.api.nvim_get_current_buf()
  if vim.w[current_win].luanphan_dependency_tree then
    local editor_win = vim.w[current_win].luanphan_dependency_editor_win
    if editor_win and vim.api.nvim_win_is_valid(editor_win) then
      vim.api.nvim_set_current_win(editor_win)
    else
      vim.cmd("wincmd p")
    end
    return
  end
  if tree_api.tree.is_tree_buf(current_buf) then
    vim.cmd("wincmd p")
    return
  end

  local file, editor_win, editor_buf = editor_file()
  local workspace = normalize(vim.fn.getcwd())
  if file and workspace and not is_within(file, workspace) then
    open_dependency_tree(file, editor_win)
    return
  end

  if file then
    focus_workspace_file(tree_api, file, editor_buf, workspace)
  else
    tree_api.tree.open()
  end
end

function M.toggle(tree_api)
  local win, buf = dependency_window()
  if win then
    vim.api.nvim_win_close(win, true)
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    return
  end

  tree_api.tree.toggle(false, true)
end

return M
