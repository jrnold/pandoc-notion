local t  = require "support.assert"
local bj = require "support.blockjson"

-- These exist to PIN the design doc 4 convention, not to check correctness --
-- the round-trip test covers that. A refactor cannot silently rename a class
-- and still pass.
local checked = 0
for _, subdir in ipairs({ "blocks", "inlines", "properties",
                          "unhydrated", "adversarial" }) do
  for _, path in ipairs(bj.list(subdir)) do
    local name   = path:match("([^/\\]+)%.json$")
    local golden = bj.ROOT .. "/tests/golden/json/" .. subdir .. "/" .. name .. ".native"
    local fh = io.open(golden, "rb")
    t.truthy(fh ~= nil, "golden exists for " .. subdir .. "/" .. name ..
                        " (run tests/regenerate_block_goldens.lua)")
    if fh then
      local expected = fh:read("a")
      fh:close()
      t.eq(bj.to_native(bj.read_file(path)), expected,
           subdir .. "/" .. name .. " matches its golden")
      checked = checked + 1
    end
  end
end

t.eq(checked, 38, "every fixture has a golden, checked " .. checked)
