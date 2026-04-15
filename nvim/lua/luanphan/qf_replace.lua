-- Project search → quickfix → replace across files
--
-- 1) g/  — Telescope live_grep (ripgrep project-wide)
-- 2) In the picker: <C-q> — send *all* current results to quickfix and open it (Telescope default)
-- 3) :copen — show the quickfix list if you closed it
-- 4) <leader>sr or :QfReplace — prompt for pattern / replacement, then :cfdo %s//… | update on each *file* in the list
--
-- :cfdo runs the substitute once per *file* (good for renaming a symbol everywhere in those files).
-- For line-by-line edits on each quickfix entry, use :cdo instead (see :help :cdo).

local M = {}

local function qf_nonempty()
  return #vim.fn.getqflist() > 0
end

--- Prompt for search + replacement; run |:cfdo| substitute on each file in the quickfix list.
function M.prompt_cfdo_substitute()
  if not qf_nonempty() then
    vim.notify(
      "Quickfix is empty. Use g/ to search, then <C-q> in Telescope to send results here.",
      vim.log.levels.WARN
    )
    return
  end

  vim.ui.input({ prompt = "Replace pattern (|search-regex|): " }, function(pattern)
    if not pattern or pattern == "" then
      return
    end
    vim.ui.input({ prompt = "Replace with: " }, function(replacement)
      if replacement == nil then
        return
      end
      replacement = replacement or ""
      -- Use # as :s delimiter to reduce clashes with / in paths or patterns
      local d = "#"
      local function esc(s)
        return (s:gsub("\\", "\\\\"):gsub(d, "\\" .. d))
      end
      local lhs, rhs = esc(pattern), esc(replacement)
      vim.cmd(string.format("cfdo %%s%s%s%s%s%sg | update", d, lhs, d, rhs, d))
    end)
  end)
end

--- Same as |prompt_cfdo_substitute| but |:cdo| — one substitution per quickfix *line* (each match).
function M.prompt_cdo_substitute()
  if not qf_nonempty() then
    vim.notify(
      "Quickfix is empty. Use g/ to search, then <C-q> in Telescope to send results here.",
      vim.log.levels.WARN
    )
    return
  end

  vim.ui.input({ prompt = "Replace pattern (|search-regex|, line-wise): " }, function(pattern)
    if not pattern or pattern == "" then
      return
    end
    vim.ui.input({ prompt = "Replace with: " }, function(replacement)
      if replacement == nil then
        return
      end
      replacement = replacement or ""
      local d = "#"
      local function esc(s)
        return (s:gsub("\\", "\\\\"):gsub(d, "\\" .. d))
      end
      local lhs, rhs = esc(pattern), esc(replacement)
      vim.cmd(string.format("cdo %%s%s%s%s%s%sg | update", d, lhs, d, rhs, d))
    end)
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("QfReplace", function()
    M.prompt_cfdo_substitute()
  end, { desc = "Replace in all files listed in quickfix (cfdo)" })

  vim.api.nvim_create_user_command("QfReplaceLine", function()
    M.prompt_cdo_substitute()
  end, { desc = "Replace on each quickfix line (cdo)" })
end

return M
