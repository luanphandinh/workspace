return function(use)
  use {
    "mg979/vim-visual-multi",
    event = "BufReadPre",
    setup = function()
      -- Use visual mode as the main entry point
      vim.g.VM_maps = {
        -- Find and select all occurrences of the word under cursor
        ["Find Under"] = "<C-n>",
        ["Find Subword Under"] = "<C-n>",

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
  }
end
