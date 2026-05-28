local M = {}

local function move(spec, from, to)
  if spec[from] ~= nil and spec[to] == nil then
    spec[to] = spec[from]
  end
  spec[from] = nil
end

local normalize

local function normalize_dependencies(deps)
  if type(deps) ~= "table" then
    return deps
  end

  local out = {}
  for key, dep in pairs(deps) do
    if type(dep) == "table" and dep[1] ~= nil then
      out[key] = normalize(dep)
    else
      out[key] = dep
    end
  end
  return out
end

normalize = function(spec)
  if type(spec) == "string" then
    return { spec }
  end
  if type(spec) ~= "table" then
    error("invalid plugin spec: " .. type(spec))
  end

  local out = vim.deepcopy(spec)
  move(out, "requires", "dependencies")
  move(out, "run", "build")
  move(out, "as", "name")
  move(out, "tag", "version")
  move(out, "setup", "init")

  if out.opt ~= nil and out.lazy == nil then
    out.lazy = out.opt
  end
  out.opt = nil
  out.dependencies = normalize_dependencies(out.dependencies)

  return out
end

function M.collect()
  local specs = {}
  local function use(spec)
    table.insert(specs, normalize(spec))
  end
  return specs, use
end

return M
