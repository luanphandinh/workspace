return {
  {
    "mg979/vim-visual-multi",
    event = "BufReadPre",
    init = function()
      -- Use visual mode as the main entry point
      vim.g.VM_maps = {
        -- Start with visual selection
        ["Select Cursor Down"] = "<C-Down>",
        ["Select Cursor Up"] = "<C-Up>",

        -- Add cursor without selection
        ["Add Cursor Down"] = "<S-Down>",
        ["Add Cursor Up"] = "<S-Up>",

        -- Skip current and find next
        ["Skip Region"] = "<C-x>",

        -- Remove current cursor
        ["Remove Region"] = "<C-p>",

        -- Undo/redo
        ["Undo"] = "u",
        ["Redo"] = "<C-r>",
      }
    end,
  },
}
