local dir = (arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/../?.lua;" .. dir .. "/?.lua;" .. package.path

local nfm = require "support.nfm"

local READER = nfm.ROOT .. "/notion-markdown-reader.lua"

-- Goldens are generated via a wide --columns so pandoc's native writer does
-- not line-wrap Attr-bearing constructors (e.g. Header/Div/Span with
-- attributes). nfm.to_native does not set this, and it is not our place to
-- change it here since other suites depend on it -- so this helper shells
-- out on its own with the flag added.
local function to_native_wide(text)
  return pandoc.pipe("pandoc", { "--columns=1000", "-f", READER, "-t", "native" }, text)
end

local SUBDIRS = { "blocks", "inlines", "nesting", "adversarial", "official" }
local written = 0

for _, sub in ipairs(SUBDIRS) do
  os.execute("mkdir -p " .. nfm.ROOT .. "/tests/golden/" .. sub)
  for _, path in ipairs(nfm.list(sub)) do
    local name = path:match("([^/]+)%.nfm$")
    local out  = to_native_wide(nfm.read_file(path))
    local dest = nfm.ROOT .. "/tests/golden/" .. sub .. "/" .. name .. ".native"
    local fh = assert(io.open(dest, "wb"))
    fh:write(out)
    fh:close()
    written = written + 1
  end
end

print(string.format("wrote %d golden files", written))
