local t   = require "support.assert"
local nfm = require "support.nfm"

local SUBDIRS = { "blocks", "inlines", "nesting", "adversarial" }

-- Fixtures with a known, pinned reason not to be byte-identical on the first
-- pass. Each is still required to be idempotent below, and its specific
-- known behavior is asserted in its own dedicated test file. Guarded below
-- so this table can never be a silent, permanent mute: a listed fixture that
-- starts round-tripping byte-identically, or a key that no longer names a
-- fixture on disk, fails the suite loudly instead of staying green forever.
local KNOWN_NOT_BYTE_IDENTICAL = {
  ["tab-in-fence.nfm"]                     = true,  -- see tests/tab_in_fence_test.lua
  ["table-colgroup.nfm"]                   = true,  -- see tests/colgroup_test.lua
  ["table-pipe.nfm"]                       = true,  -- see tests/pipe_table_test.lua: normalizes to <table>
  ["pipe-not-table.nfm"]                   = true,  -- see tests/pipe_table_test.lua: literal "|" gets escaped
  ["pipe-table-truncated-delimiter.nfm"]   = true,  -- see tests/pipe_table_test.lua: literal "|" gets escaped
}

local seen_names = {}
local count = 0
for _, sub in ipairs(SUBDIRS) do
  for _, path in ipairs(nfm.list(sub)) do
    count = count + 1
    local src = nfm.read_file(path):gsub("\n$", "")
    local once = nfm.to_nfm(src):gsub("\n$", "")
    local name = path:match("[^/]+$")
    seen_names[name] = true

    -- Authored fixtures are written in canonical form, so the first pass must
    -- already be byte-identical -- except the pinned exceptions above, which
    -- must instead demonstrably NOT be byte-identical (staleness guard).
    if KNOWN_NOT_BYTE_IDENTICAL[name] then
      t.truthy(once ~= src, name .. " is listed in KNOWN_NOT_BYTE_IDENTICAL"
        .. " but now round-trips byte-identically; remove the exception")
    else
      t.eq(once, src, "round-trip is byte-identical: " .. name)
    end

    -- And conversion is stable: applying it again changes nothing.
    local twice = nfm.to_nfm(once):gsub("\n$", "")
    t.eq(twice, once, "round-trip is idempotent: " .. name)
  end
end

for name in pairs(KNOWN_NOT_BYTE_IDENTICAL) do
  t.truthy(seen_names[name], name .. " is listed in KNOWN_NOT_BYTE_IDENTICAL"
    .. " but no such fixture exists on disk")
end

t.eq(count, 44, "corpus has exactly 44 fixtures, found " .. count)

-- Official fixtures are transcribed verbatim from Notion's documentation, so
-- their formatting is not ours to control. Assert STABILITY (f(f(x)) == f(x))
-- rather than byte-identity: the first pass may normalize, but no pass after
-- it may change anything.
local official = 0
for _, path in ipairs(nfm.list("official")) do
  official = official + 1
  local name  = path:match("[^/]+$")
  local src   = nfm.read_file(path):gsub("\n$", "")
  local once  = nfm.to_nfm(src):gsub("\n$", "")
  local twice = nfm.to_nfm(once):gsub("\n$", "")
  t.eq(twice, once, "official fixture is stable: " .. name)
  t.truthy(#once > 0, "official fixture produces output: " .. name)
end
t.truthy(official >= 4, "all four official fixtures present, found " .. official)
