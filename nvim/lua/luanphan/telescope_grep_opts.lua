-- Flags for Telescope |live_grep| (|g/|). Persisted in |g:| so the next picker uses them.
-- Default: ignore-case on (-i), fixed-string on (-F). <leader>t1 = strict case, t2 = regex.

local M = {}

--- Open project live grep with ripgrep flags from |g:| toggles.
--- Telescope does not merge |telescope.setup| `{ pickers = { live_grep = … } }` into
--- |:Telescope live_grep|; you must call this (or pass opts in Lua) for |additional_args| to run.
function M.live_grep()
  local actions = require("telescope.actions")
  local finders = require("telescope.finders")
  local make_entry = require("telescope.make_entry")
  local pickers = require("telescope.pickers")
  local sorters = require("telescope.sorters")
  local tconf = require("telescope.config")
  local conf = tconf.values
  local opts = vim.deepcopy(tconf.pickers.live_grep or {})
  opts.additional_args = M.additional_args
  opts.cwd = opts.cwd or vim.uv.cwd()

  local args = vim.deepcopy(opts.vimgrep_arguments or conf.vimgrep_arguments)
  vim.list_extend(args, opts.additional_args(opts))
  local search_dirs = vim.tbl_map(vim.fn.expand, opts.search_dirs or {})

  local finder = finders.new_job(function(prompt)
    if not prompt or prompt == "" then
      return nil
    end
    return vim.list_extend(vim.deepcopy(args), vim.list_extend({ "--", prompt }, search_dirs))
  end, opts.entry_maker or make_entry.gen_from_vimgrep(opts), nil, opts.cwd)

  pickers.new(opts, {
    prompt_title = "Live Grep",
    finder = finder,
    previewer = conf.grep_previewer(opts),
    sorter = require("luanphan.search_priority").wrap_sorter(sorters.highlighter_only(opts)),
    attach_mappings = function(_, map)
      map("i", "<C-Space>", actions.to_fuzzy_refine)
      return true
    end,
    push_cursor_on_edit = true,
  }):find()
end

--- Extra ripgrep args for |telescope.builtin.live_grep|.
function M.additional_args()
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
