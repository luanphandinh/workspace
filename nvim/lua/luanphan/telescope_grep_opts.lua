-- Flags for Telescope |live_grep| (|g/|). Persisted in |g:| so the next picker uses them.
-- Default: ignore-case on (-i), fixed-string on (-F). <leader>t1 = strict case, t2 = regex.

local M = {}
local live_grep_cache

local function cached_finder(opts)
  local async = require("plenary.async")
  local generation = 0
  local timer = vim.uv.new_timer()
  local finder = opts.finders.new_job(opts.command_generator, opts.entry_maker, nil, opts.cwd)
  local run_finder = async.void(function(...)
    finder(...)
  end)
  local cached = opts.cached
  local can_replay = cached and cached.results ~= nil
  local active_prompt
  local active_results
  local active_complete = false

  local function save(results)
    live_grep_cache = {
      identity = opts.identity,
      query = active_prompt,
      results = results,
    }
  end

  return setmetatable({
    close = function()
      generation = generation + 1
      timer:stop()
      finder:close()
      if active_prompt ~= nil then
        save(active_complete and active_results or nil)
      end
      if not timer:is_closing() then
        timer:close()
      end
    end,
  }, {
    __call = function(_, prompt, process_result, process_complete)
      generation = generation + 1
      local request_generation = generation
      timer:stop()
      finder:close()
      opts.on_search()

      active_prompt = prompt or ""
      active_results = {}
      active_complete = false
      save(nil)

      if not prompt or prompt == "" then
        active_complete = true
        save(active_results)
        process_complete()
        return
      end

      if can_replay and prompt == cached.query then
        can_replay = false
        for index, line in ipairs(cached.results) do
          local entry = opts.entry_maker(line)
          if entry then
            entry.index = index
            active_results[#active_results + 1] = line
            if process_result(entry) then
              return
            end
          end
        end
        active_complete = true
        save(active_results)
        process_complete()
        return
      end
      can_replay = false

      timer:start(opts.delay, 0, function()
        vim.schedule(function()
          if request_generation ~= generation then
            return
          end
          run_finder(prompt, function(entry)
            if request_generation ~= generation then
              return true
            end
            if entry and type(entry.value) == "string" then
              active_results[#active_results + 1] = entry.value
            end
            return process_result(entry)
          end, function()
            if request_generation == generation then
              active_complete = true
              save(active_results)
              process_complete()
            end
          end)
        end)
      end)
    end,
  })
end

function M.content_highlights(prompt, display)
  local _, coordinates_end = display:find(":%d+:%d+:")
  if not coordinates_end then
    return {}
  end

  local positions = require("telescope.algos.fzy").positions(prompt, display:sub(coordinates_end + 1))
  for index, position in ipairs(positions) do
    positions[index] = coordinates_end + position
  end
  return positions
end

--- Open project live grep with ripgrep flags from |g:| toggles.
--- Telescope does not merge |telescope.setup| `{ pickers = { live_grep = … } }` into
--- |:Telescope live_grep|; you must call this (or pass opts in Lua) for |additional_args| to run.
function M.live_grep(default_text)
  local actions = require("telescope.actions")
  local finders = require("telescope.finders")
  local make_entry = require("telescope.make_entry")
  local pickers = require("telescope.pickers")
  local sorters = require("telescope.sorters")
  local tconf = require("telescope.config")
  local conf = tconf.values
  local search_rules = require("luanphan.search_priority")
  local rules = search_rules.read_rules()
  local opts = vim.deepcopy(tconf.pickers.live_grep or {})
  opts.additional_args = function(config)
    return M.additional_args(config, rules)
  end
  opts.cwd = opts.cwd or vim.uv.cwd()

  local args = vim.deepcopy(opts.vimgrep_arguments or conf.vimgrep_arguments)
  vim.list_extend(args, opts.additional_args(opts))
  local search_dirs = vim.tbl_map(vim.fn.expand, opts.search_dirs or {})
  local cwd = vim.uv.fs_realpath(opts.cwd) or vim.fs.normalize(opts.cwd)
  local identity_parts = vim.list_extend({ cwd }, vim.deepcopy(args))
  vim.list_extend(identity_parts, search_dirs)
  local identity = table.concat(identity_parts, "\0")
  local cached
  if default_text == nil and live_grep_cache and live_grep_cache.identity == identity then
    cached = live_grep_cache
  end
  opts.default_text = default_text or (cached and cached.query) or opts.default_text
  opts.cache_picker = false

  local picker
  local finder = cached_finder({
    cached = cached,
    command_generator = function(prompt)
      if not prompt or prompt == "" then
        return nil
      end
      return vim.list_extend(vim.deepcopy(args), vim.list_extend({ "--", prompt }, search_dirs))
    end,
    cwd = opts.cwd,
    delay = 200,
    entry_maker = opts.entry_maker or make_entry.gen_from_vimgrep(opts),
    finders = finders,
    identity = identity,
    on_search = function()
      if picker and vim.api.nvim_buf_is_valid(picker.results_bufnr) then
        vim.api.nvim_buf_set_lines(picker.results_bufnr, 0, -1, false, { "" })
      end
    end,
  })

  local grep_sorter = sorters.highlighter_only(opts)
  grep_sorter.highlighter = function(_, prompt, display)
    return M.content_highlights(prompt, display)
  end

  picker = pickers.new(opts, {
    prompt_title = "Live Grep",
    finder = finder,
    previewer = conf.grep_previewer(opts),
    sorter = search_rules.wrap_sorter(grep_sorter, rules),
    attach_mappings = function(_, map)
      map("i", "<C-Space>", actions.to_fuzzy_refine)
      return true
    end,
    push_cursor_on_edit = true,
  })
  picker:find()
end

--- Extra ripgrep args for |telescope.builtin.live_grep|.
function M.additional_args(_, rules)
  local args = {}
  if vim.g.luanphan_show_dotfiles == 1 then
    table.insert(args, "--hidden")
  end
  -- Default Telescope |vimgrep_arguments| includes |--smart-case|, which still matches
  -- all-lowercase patterns case-insensitively without |-i|. When the user wants strict case
  -- matching, append |--case-sensitive| so it overrides |--smart-case|.
  if (vim.g.luanphan_live_grep_case_sensitive or 0) == 0 then
    table.insert(args, "-i")
  else
    table.insert(args, "--case-sensitive")
  end
  -- Regex when g: var is 1; default unset/0 → --fixed-strings (literal).
  if (vim.g.luanphan_live_grep_regex or 0) == 0 then
    table.insert(args, "--fixed-strings")
  end
  vim.list_extend(args, require("luanphan.search_priority").ignore_args(rules))
  return args
end

local function flip(name)
  vim.g[name] = (vim.g[name] or 0) == 0 and 1 or 0
end

function M.toggle_case_sensitive()
  flip("luanphan_live_grep_case_sensitive")
  M.notify_state()
end

function M.toggle_regex()
  flip("luanphan_live_grep_regex")
  M.notify_state()
end

function M.notify_state()
  -- Align wording with ripgrep: g:luanphan_live_grep_case_sensitive=1 → strict case (ignore-case off).
  local ignore_case_on = (vim.g.luanphan_live_grep_case_sensitive or 0) == 0
  local fixed_string_on = (vim.g.luanphan_live_grep_regex or 0) == 0
  vim.notify(
    string.format(
      "live_grep: ignore-case %s · fixed-string %s",
      ignore_case_on and "on" or "off",
      fixed_string_on and "on" or "off"
    ),
    vim.log.levels.INFO
  )
end

return M
