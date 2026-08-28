local dir = (arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/../?.lua;" .. dir .. "/?.lua;" .. package.path

local t = require "support.assert"

local suites = {
  "unit.escape_test",
}

for _, s in ipairs(suites) do require(s) end

os.exit(t.report())
