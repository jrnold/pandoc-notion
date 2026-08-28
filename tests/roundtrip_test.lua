local t   = require "support.assert"
local nfm = require "support.nfm"

local SUBDIRS = { "blocks", "inlines", "nesting", "adversarial" }

-- Fixtures with a known, pinned reason not to be byte-identical on the first
-- pass. Each is still required to be idempotent below, and its specific
-- known behavior is asserted in its own dedicated test file.
local KNOWN_NOT_BYTE_IDENTICAL = {
  ["tab-in-fence.nfm"] = true,  -- see tests/tab_in_fence_test.lua
}

local count = 0
for _, sub in ipairs(SUBDIRS) do
  for _, path in ipairs(nfm.list(sub)) do
    count = count + 1
    local src = nfm.read_file(path):gsub("\n$", "")
    local once = nfm.to_nfm(src):gsub("\n$", "")
    local name = path:match("[^/]+$")

    -- Authored fixtures are written in canonical form, so the first pass must
    -- already be byte-identical -- except the pinned exceptions above.
    if not KNOWN_NOT_BYTE_IDENTICAL[name] then
      t.eq(once, src, "round-trip is byte-identical: " .. name)
    end

    -- And conversion is stable: applying it again changes nothing.
    local twice = nfm.to_nfm(once):gsub("\n$", "")
    t.eq(twice, once, "round-trip is idempotent: " .. name)
  end
end

t.truthy(count >= 39, "corpus has at least 39 fixtures, found " .. count)
