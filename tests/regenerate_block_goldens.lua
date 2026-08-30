local dir = (arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/../?.lua;" .. dir .. "/?.lua;" .. package.path

local bj = require "support.blockjson"

for _, subdir in ipairs({ "blocks", "inlines", "properties",
                          "unhydrated", "adversarial" }) do
  for _, path in ipairs(bj.list(subdir)) do
    local name = path:match("([^/\\]+)%.json$")
    local out  = bj.ROOT .. "/tests/golden/json/" .. subdir .. "/" .. name .. ".native"
    os.execute("mkdir -p " .. bj.ROOT .. "/tests/golden/json/" .. subdir)
    local fh = assert(io.open(out, "wb"))
    fh:write(bj.to_native(bj.read_file(path)))
    fh:close()
    print("wrote " .. out)
  end
end
