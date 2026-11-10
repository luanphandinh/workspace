local M = {}

local function git_lines(repo, args)
  local command = { "git", "-C", repo }
  vim.list_extend(command, args)
  local output = vim.fn.systemlist(command)
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return output
end

local function git_first(repo, args)
  local output = git_lines(repo, args)
  if not output or not output[1] then
    return nil
  end
  local value = vim.trim(output[1])
  return value ~= "" and value or nil
end

local function remote_url(repo, branch)
  local candidates = {}
  local seen = {}
  local function add(name)
    if name and name ~= "." and not seen[name] then
      seen[name] = true
      candidates[#candidates + 1] = name
    end
  end

  if branch then
    add(git_first(repo, { "config", "--get", "branch." .. branch .. ".remote" }))
  end
  add("origin")
  for _, name in ipairs(git_lines(repo, { "remote" }) or {}) do
    add(vim.trim(name))
  end

  for _, name in ipairs(candidates) do
    local url = git_first(repo, { "remote", "get-url", name })
    if url then
      return url
    end
  end
  return nil
end

local function remote_base(remote)
  remote = vim.trim(remote or ""):gsub("/+$", "")
  local scheme, authority, path = remote:match("^(https?)://([^/]+)/(.+)$")
  if scheme then
    authority = authority:match("@(.+)$") or authority
    path = path:gsub("%.git$", "")
    return scheme .. "://" .. authority .. "/" .. path, authority:match("^([^:]+)")
  end

  authority, path = remote:match("^ssh://([^/]+)/(.+)$")
  if authority then
    authority = authority:match("@(.+)$") or authority
    authority = authority:gsub(":%d+$", "")
    path = path:gsub("%.git$", "")
    return "https://" .. authority .. "/" .. path, authority
  end

  local host
  host, path = remote:match("^[^@]+@([^:]+):(.+)$")
  if host then
    path = path:gsub("%.git$", "")
    return "https://" .. host .. "/" .. path, host
  end
  return nil, nil
end

local function encode_path(value)
  return (value:gsub("[^%w%-%._~/]", function(char)
    return string.format("%%%02X", string.byte(char))
  end))
end

function M.build_file_url(remote, ref, path, line)
  local base, host = remote_base(remote)
  if not base then
    return nil, "Remote URL is not an HTTP or SSH repository URL"
  end

  local separator = host:lower():find("gitlab", 1, true) and "/-/blob/" or "/blob/"
  local url = base .. separator .. encode_path(ref) .. "/" .. encode_path(path)
  if line and line > 0 then
    url = url .. "#L" .. line
  end
  return url
end

function M.url_for_file(file, line)
  if not file or file == "" or vim.fn.filereadable(file) ~= 1 then
    return nil, "Current buffer is not a file"
  end

  file = (vim.uv or vim.loop).fs_realpath(file) or file
  local directory = vim.fn.fnamemodify(file, ":h")
  local repo = git_first(directory, { "rev-parse", "--show-toplevel" })
  if not repo then
    return nil, "Current file is not inside a git repository"
  end

  local relative = vim.fs.relpath(repo, file)
  if not relative or not git_first(repo, { "ls-files", "--error-unmatch", "--", relative }) then
    return nil, "Current file is not tracked by git"
  end

  local branch = git_first(repo, { "symbolic-ref", "--quiet", "--short", "HEAD" })
  local ref = branch or git_first(repo, { "rev-parse", "HEAD" })
  if not ref then
    return nil, "Current repository has no branch or commit"
  end

  local remote = remote_url(repo, branch)
  if not remote then
    return nil, "Current repository has no git remote"
  end
  return M.build_file_url(remote, ref, relative, line)
end

function M.open_current_file()
  local file = vim.api.nvim_buf_get_name(0)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local url, err = M.url_for_file(file, line)
  if not url then
    vim.notify(err, vim.log.levels.WARN)
    return false
  end
  return require("luanphan.terminal_references").open_url(url)
end

return M
