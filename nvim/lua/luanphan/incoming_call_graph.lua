local M = {}

local prepare_method = "textDocument/prepareCallHierarchy"
local incoming_method = "callHierarchy/incomingCalls"
local go_test_prefixes = { "Test", "Benchmark", "Fuzz", "Example" }

local function is_go_test_item(item)
  local path = item.uri and vim.uri_to_fname(item.uri) or ""
  if not path:match("%.go$") then
    return false
  end
  if path:match("_test%.go$") then
    return true
  end

  local name = item.name or ""
  for _, prefix in ipairs(go_test_prefixes) do
    if name:sub(1, #prefix) == prefix then
      local suffix_start = name:sub(#prefix + 1, #prefix + 1)
      if suffix_start == "" or not suffix_start:match("%l") then
        return true
      end
    end
  end
  return false
end

local function item_key(item)
  local range = item.selectionRange or item.range or {}
  local start = range.start or {}
  return table.concat({ item.uri or "", start.line or 0, start.character or 0, item.name or "" }, "\0")
end

local function item_label(item)
  local path = item.uri and vim.uri_to_fname(item.uri) or ""
  local range = item.selectionRange or item.range or {}
  local line = range.start and range.start.line + 1 or 1
  local location = path ~= "" and vim.fn.fnamemodify(path, ":.") .. ":" .. line or ""
  if location == "" then
    return item.name or "<anonymous>"
  end
  return string.format("%s  %s", item.name or "<anonymous>", location)
end

local function window_configs(lines)
  local max_width = 0
  for _, line in ipairs(lines) do
    max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
  end

  local available_width = math.max(2, vim.o.columns - 7)
  local available_height = math.max(1, vim.o.lines - vim.o.cmdheight - 4)
  local max_graph_width = math.max(1, math.floor(available_width * 0.48))
  local graph_width = math.min(math.max(32, max_width + 2), max_graph_width)
  graph_width = math.max(1, math.min(graph_width, available_width - 1))
  local preview_width = math.max(1, available_width - graph_width)
  local editor_height = math.max(1, vim.o.lines - vim.o.cmdheight)
  local graph_height = math.min(math.max(3, #lines), available_height)
  local preview_height = math.min(math.max(3, math.floor(editor_height * 0.8) - 2), available_height)
  local total_width = graph_width + preview_width + 5
  local col = math.max(0, math.floor((vim.o.columns - total_width) / 2))
  local graph_row = math.max(0, math.floor((editor_height - graph_height - 2) / 2))
  local preview_row = math.max(0, math.floor((editor_height - preview_height - 2) / 2))

  return {
    relative = "editor",
    width = graph_width,
    height = graph_height,
    row = graph_row,
    col = col,
  }, {
    relative = "editor",
    width = preview_width,
    height = preview_height,
    row = preview_row,
    col = col + graph_width + 3,
  }
end

local function resize(view, lines)
  if not vim.api.nvim_win_is_valid(view.win) or not vim.api.nvim_win_is_valid(view.preview_win) then
    return
  end

  local graph_config, preview_config = window_configs(lines)
  vim.api.nvim_win_set_config(view.win, graph_config)
  vim.api.nvim_win_set_config(view.preview_win, preview_config)
end

local function create_view(source_win, encoding)
  vim.api.nvim_set_hl(0, "IncomingCallGraphFocus", { default = true, link = "Visual" })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "incoming-call-graph://" .. buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "callgraph"

  local preview_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(preview_buf, "incoming-call-preview://" .. preview_buf)
  vim.bo[preview_buf].buftype = "nofile"
  vim.bo[preview_buf].bufhidden = "wipe"
  vim.bo[preview_buf].swapfile = false
  vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, { "Select a call graph entry to preview its source." })

  local graph_config, preview_config = window_configs({ "Loading incoming calls..." })
  local win = vim.api.nvim_open_win(buf, true, vim.tbl_extend("force", graph_config, {
    style = "minimal",
    border = "rounded",
    title = " Incoming Call Graph ",
    title_pos = "center",
  }))
  local preview_win = vim.api.nvim_open_win(preview_buf, false, vim.tbl_extend("force", preview_config, {
    style = "minimal",
    border = "rounded",
    title = " Source Preview ",
    title_pos = "center",
    focusable = false,
  }))
  vim.wo[win].cursorline = true
  vim.wo[win].winhighlight = "CursorLine:IncomingCallGraphFocus"
  vim.wo[win].wrap = false
  vim.wo[preview_win].number = true
  vim.wo[preview_win].relativenumber = false
  vim.wo[preview_win].signcolumn = "no"
  vim.wo[preview_win].wrap = false
  vim.w[preview_win].luanphan_incoming_call_preview = true

  local view = {
    buf = buf,
    win = win,
    preview_win = preview_win,
    source_win = source_win,
    encoding = encoding,
    line_targets = {},
  }

  function view:update_preview()
    if not vim.api.nvim_win_is_valid(self.win) or not vim.api.nvim_win_is_valid(self.preview_win) then
      return
    end

    local line = vim.api.nvim_win_get_cursor(self.win)[1]
    local targets = self.line_targets[line]
    local target = targets and targets[1]
    local location = target and target.location
    if not location or not location.uri then
      return
    end

    local preview_source = vim.uri_to_bufnr(location.uri)
    vim.fn.bufload(preview_source)
    vim.api.nvim_win_set_buf(self.preview_win, preview_source)

    local start = location.range and location.range.start or { line = 0, character = 0 }
    local preview_line = math.max(1, math.min(start.line + 1, vim.api.nvim_buf_line_count(preview_source)))
    local ok, preview_col = pcall(vim.lsp.util._get_line_byte_from_position, preview_source, start, self.encoding)
    if not ok then
      preview_col = 0
    end
    vim.api.nvim_win_set_cursor(self.preview_win, { preview_line, preview_col })
    vim.api.nvim_win_call(self.preview_win, function()
      if self.preview_match then
        pcall(vim.fn.matchdelete, self.preview_match)
      end
      self.preview_match = vim.fn.matchaddpos("IncomingCallGraphFocus", { { preview_line } }, 20)
      vim.cmd("normal! zz")
    end)
  end

  function view:set_lines(lines, line_targets)
    if not vim.api.nvim_buf_is_valid(self.buf) then
      return
    end
    vim.bo[self.buf].modifiable = true
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
    vim.bo[self.buf].modifiable = false
    self.line_targets = line_targets or {}
    resize(self, lines)
    self:update_preview()
  end

  function view:close()
    if vim.api.nvim_win_is_valid(self.preview_win) then
      vim.api.nvim_win_close(self.preview_win, true)
    end
    if vim.api.nvim_win_is_valid(self.win) then
      vim.api.nvim_win_close(self.win, true)
    end
  end

  local function close()
    view:close()
  end

  vim.keymap.set("n", "q", close, { buffer = buf, silent = true, desc = "Close incoming call graph" })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true, desc = "Close incoming call graph" })
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      view:update_preview()
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if vim.api.nvim_win_is_valid(view.preview_win) then
        vim.api.nvim_win_close(view.preview_win, true)
      end
    end,
  })
  vim.keymap.set("n", "<CR>", function()
    local targets = view.line_targets[vim.api.nvim_win_get_cursor(0)[1]]
    if not targets or #targets == 0 then
      return
    end

    local function jump(target)
      view:close()
      if vim.api.nvim_win_is_valid(view.source_win) then
        vim.api.nvim_set_current_win(view.source_win)
      end
      vim.lsp.util.show_document(target.location, view.encoding, { focus = true, reuse_win = true })
    end

    if #targets == 1 then
      jump(targets[1])
      return
    end
    vim.ui.select(targets, {
      prompt = "Select immediate child call:",
      format_item = function(target)
        return target.label
      end,
    }, function(target)
      if target then
        jump(target)
      end
    end)
  end, { buffer = buf, silent = true, desc = "Open child call site" })

  view:set_lines({ "Loading incoming calls..." })
  return view
end

local function render(view, root_key, nodes, failed_requests)
  local lines = {}
  local line_targets = {}
  local callees = {}
  local roots = {}

  for key in pairs(nodes) do
    callees[key] = {}
  end
  for callee_key, node in pairs(nodes) do
    if #node.callers == 0 then
      roots[#roots + 1] = callee_key
    end
    for _, caller_key in ipairs(node.callers) do
      callees[caller_key][#callees[caller_key] + 1] = {
        key = callee_key,
        ranges = node.caller_ranges[caller_key] or {},
      }
    end
  end
  if #roots == 0 then
    roots[1] = root_key
  end

  local function sort_keys(keys)
    table.sort(keys, function(left, right)
      return item_label(nodes[left].item) < item_label(nodes[right].item)
    end)
  end
  sort_keys(roots)

  local function sort_edges(edges)
    table.sort(edges, function(left, right)
      return item_label(nodes[left.key].item) < item_label(nodes[right.key].item)
    end)
  end

  local function targets_for(key, children)
    local targets = {}
    local caller = nodes[key].item
    local path = caller.uri and vim.uri_to_fname(caller.uri) or ""
    for _, child in ipairs(children) do
      for _, range in ipairs(child.ranges) do
        targets[#targets + 1] = {
          label = string.format(
            "%s:%d -> %s",
            vim.fn.fnamemodify(path, ":."),
            range.start.line + 1,
            nodes[child.key].item.name or "<anonymous>"
          ),
          location = { uri = caller.uri, range = range },
        }
      end
    end
    if #targets == 0 then
      targets[1] = {
        label = item_label(caller),
        location = { uri = caller.uri, range = caller.selectionRange or caller.range },
      }
    end
    return targets
  end

  local expanded = {}
  local function append_path(key, prefix, marker, path)
    local children = callees[key]
    sort_edges(children)
    local label = item_label(nodes[key].item)
    if key == root_key then
      label = label .. "  [focused]"
    end
    if path[key] then
      label = label .. "  [cycle]"
    end
    lines[#lines + 1] = prefix .. marker .. label
    line_targets[#lines] = targets_for(key, children)
    if path[key] then
      return
    end
    if expanded[key] then
      lines[#lines] = lines[#lines] .. "  [shared]"
      return
    end

    expanded[key] = true
    path[key] = true
    local child_prefix = prefix
    if marker == "└ " then
      child_prefix = prefix .. "  "
    elseif marker == "├ " then
      child_prefix = prefix .. "│ "
    end
    for index, child in ipairs(children) do
      local is_last = index == #children
      local marker = is_last and "└ " or "├ "
      append_path(child.key, child_prefix, marker, path)
    end
    path[key] = nil
  end

  for index, key in ipairs(roots) do
    if index > 1 then
      lines[#lines + 1] = ""
    end
    append_path(key, "", "", {})
  end
  if failed_requests > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("[%d incoming-call request(s) failed]", failed_requests)
  end
  view:set_lines(lines, line_targets)
end

local function load_graph(client, bufnr, root, view)
  local nodes = {}
  local visited = {}
  local pending = 0
  local failed_requests = 0
  local root_key = item_key(root)

  local request_item
  request_item = function(item)
    local key = item_key(item)
    if visited[key] then
      return
    end
    visited[key] = true
    nodes[key] = nodes[key] or { item = item, callers = {}, caller_set = {}, caller_ranges = {} }
    pending = pending + 1

    local accepted = client:request(incoming_method, { item = item }, function(err, result)
      pending = pending - 1
      if err then
        failed_requests = failed_requests + 1
      else
        for _, call in ipairs(result or {}) do
          local caller = call.from
          if not is_go_test_item(caller) then
            local caller_key = item_key(caller)
            nodes[caller_key] = nodes[caller_key]
              or { item = caller, callers = {}, caller_set = {}, caller_ranges = {} }
            if not nodes[key].caller_set[caller_key] then
              nodes[key].caller_set[caller_key] = true
              nodes[key].callers[#nodes[key].callers + 1] = caller_key
              nodes[key].caller_ranges[caller_key] = call.fromRanges or {}
            end
            request_item(caller)
          end
        end
      end

      if pending == 0 then
        render(view, root_key, nodes, failed_requests)
      end
    end, bufnr)

    if not accepted then
      pending = pending - 1
      failed_requests = failed_requests + 1
      if pending == 0 then
        render(view, root_key, nodes, failed_requests)
      end
    end
  end

  request_item(root)
end

function M.open()
  local bufnr = vim.api.nvim_get_current_buf()
  local source_win = vim.api.nvim_get_current_win()
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = prepare_method })
  if #clients == 0 then
    vim.notify("No LSP client supports call hierarchy", vim.log.levels.WARN)
    return
  end

  local client = clients[1]
  local view = create_view(source_win, client.offset_encoding)
  local params = vim.lsp.util.make_position_params(source_win, client.offset_encoding)
  local accepted = client:request(prepare_method, params, function(err, result)
    if err then
      view:set_lines({ "Call hierarchy request failed: " .. (err.message or tostring(err)) })
      return
    end
    if not result or not result[1] then
      view:set_lines({ "No call hierarchy item found" })
      return
    end
    if is_go_test_item(result[1]) then
      view:set_lines({ "Go test functions are excluded from the call graph" })
      return
    end
    load_graph(client, bufnr, result[1], view)
  end, bufnr)

  if not accepted then
    view:set_lines({ "LSP client stopped before the request was sent" })
  end
end

return M
