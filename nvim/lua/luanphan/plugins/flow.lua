local function flow(method, ...)
  local args = { ... }
  return function()
    require("luanphan.flow")[method](unpack(args))
  end
end

return {
  {
    "luanphan-flow",
    virtual = true,
    keys = {
      { "<leader>ha", flow("add"), desc = "Add current line" },
      { "<leader>hh", flow("toggle_menu"), desc = "Menu" },
      { "<leader>h1", flow("select", 1), desc = "Entry 1" },
      { "<leader>h2", flow("select", 2), desc = "Entry 2" },
      { "<leader>h3", flow("select", 3), desc = "Entry 3" },
      { "<leader>h4", flow("select", 4), desc = "Entry 4" },
      { "<C-P>", flow("previous"), desc = "Flow previous entry" },
      { "<C-N>", flow("next"), desc = "Flow next entry" },
    },
  },
}
