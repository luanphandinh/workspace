return {
  {
    "luanphan-go-file-config",
    virtual = true,
    ft = "go",
    config = function()
      require("luanphan.file_configs.go").setup()
    end,
  },
  {
    "luanphan-lua-file-config",
    virtual = true,
    ft = "lua",
    config = function()
      require("luanphan.file_configs.lua").setup()
    end,
  },
  {
    "luanphan-json-file-config",
    virtual = true,
    ft = "json",
    config = function()
      require("luanphan.file_configs.json").setup()
    end,
  },
}
