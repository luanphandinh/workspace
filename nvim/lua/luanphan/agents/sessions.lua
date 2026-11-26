local uuid = "^" .. string.rep("%x", 8) .. ("%-" .. string.rep("%x", 4)):rep(3) .. "%-" .. string.rep("%x", 12) .. "$"
return require("luanphan.view_container.session_store").create({
  valid_id = function(id) return type(id) == "string" and id:match(uuid) ~= nil end,
  directory = function(kind)
    return vim.g["luanphan_" .. kind .. "_sessions_dir"]
      or (vim.fn.stdpath("state") .. "/workspace-" .. kind .. "-sessions")
  end,
})
