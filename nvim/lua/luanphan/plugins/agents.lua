return {
  {
    "luanphan-cursor-agent",
    virtual = true,
    keys = {
      { "<leader>ac", mode = "n", desc = "Toggle agent terminal" },
      { "<leader>af", mode = "n", desc = "Focus agent terminal" },
      { "<leader>as", mode = "x", desc = "Send selection to agent" },
    },
    config = function()
      require("luanphan.cursor_agent").setup()
    end,
  },
  {
    "luanphan-claude-agent",
    virtual = true,
    keys = {
      { "<leader>xc", mode = "n", desc = "Toggle agent terminal" },
      { "<leader>xf", mode = "n", desc = "Focus agent terminal" },
      { "<leader>xs", mode = "x", desc = "Send selection to agent" },
    },
    config = function()
      require("luanphan.claude_agent").setup()
    end,
  },
  {
    "luanphan-codex-agent",
    virtual = true,
    keys = {
      { "<leader>cc", mode = "n", desc = "Toggle agent terminal" },
      { "<leader>cf", mode = "n", desc = "Focus agent terminal" },
      { "<leader>cs", mode = "x", desc = "Send selection to agent" },
    },
    config = function()
      require("luanphan.codex_agent").setup()
    end,
  },
}
