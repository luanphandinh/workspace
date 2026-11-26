-- Picker used by panels: Telescope when it is available, vim.ui.select otherwise.
local M = {}

function M.select(title, items, on_select, picker_opts)
  local ok_pickers, pickers = pcall(require, "telescope.pickers")
  local ok_finders, finders = pcall(require, "telescope.finders")
  local ok_config, telescope_config = pcall(require, "telescope.config")
  local ok_actions, actions = pcall(require, "telescope.actions")
  local ok_state, action_state = pcall(require, "telescope.actions.state")
  if not (ok_pickers and ok_finders and ok_config and ok_actions and ok_state) then
    vim.ui.select(items, {
      prompt = title,
      format_item = function(item)
        return item.display or item.label or item.id
      end,
    }, on_select)
    return
  end

  pickers
    .new({}, vim.tbl_extend("force", {
      prompt_title = title,
      finder = finders.new_table({
        results = items,
        entry_maker = function(item)
          local display = item.display or item.label or item.id
          return {
            value = item,
            display = display,
            ordinal = item.ordinal or display,
          }
        end,
      }),
      sorter = telescope_config.values.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection and selection.value then
            vim.schedule(function()
              on_select(selection.value)
            end)
          end
        end)
        return true
      end,
    }, picker_opts or {}))
    :find()
end


function M.compact_opts()
  return {
    layout_strategy = "center",
    layout_config = {
      width = function(_, columns) return math.min(96, math.floor(columns * 0.55)) end,
      height = function(_, _, lines) return math.min(16, math.floor(lines * 0.35)) end,
      prompt_position = "top",
    },
    results_title = false,
    previewer = false,
    sorting_strategy = "ascending",
  }
end

return M
