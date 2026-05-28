local function with_harpoon(fn)
  return function()
    fn(require("harpoon"))
  end
end

return {
  {
    "ThePrimeagen/harpoon",
    branch = "harpoon2", -- use harpoon2 (latest version)
    dependencies = { "nvim-lua/plenary.nvim" },
    keys = {
      { "<leader>ha", with_harpoon(function(harpoon) harpoon:list():add() end), desc = "Harpoon Add File" },
      {
        "<leader>hh",
        with_harpoon(function(harpoon) harpoon.ui:toggle_quick_menu(harpoon:list()) end),
        desc = "Harpoon Menu",
      },
      { "<leader>h1", with_harpoon(function(harpoon) harpoon:list():select(1) end), desc = "Harpoon File 1" },
      { "<leader>h2", with_harpoon(function(harpoon) harpoon:list():select(2) end), desc = "Harpoon File 2" },
      { "<leader>h3", with_harpoon(function(harpoon) harpoon:list():select(3) end), desc = "Harpoon File 3" },
      { "<leader>h4", with_harpoon(function(harpoon) harpoon:list():select(4) end), desc = "Harpoon File 4" },
      { "<C-P>", with_harpoon(function(harpoon) harpoon:list():prev() end), desc = "Harpoon Previous File" },
      { "<C-N>", with_harpoon(function(harpoon) harpoon:list():next() end), desc = "Harpoon Next File" },
    },
    config = function()
      require("harpoon"):setup()
    end,
  },
}
