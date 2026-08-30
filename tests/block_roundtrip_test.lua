local t  = require "support.assert"
local bj = require "support.blockjson"

-- Byte-identity on the first pass is expected for fixtures authored in
-- canonical form. Entries here have a documented reason not to be.
local KNOWN_NOT_BYTE_IDENTICAL = {
  -- Server-owned metadata is deliberately dropped (design doc 4.1), so a
  -- fixture carrying ids and timestamps cannot come back byte-identical.
  ["nulls.json"]        = "carries id and parent, which are dropped by design (4.1); the explicit null text.link/href are also omitted, since the writer emits those keys only when a link exists",
  ["has-children.json"] = "list-response envelope is normalized to a bare array (6.1); id is dropped by design (4.1) and has_children has no AST carrier (6.3)",
  ["media-hosted.json"] = "expiry_time is dropped; file becomes external",
  ["all-types.json"]    = "page properties are read-only (design doc 4.6); its " ..
                          "\"Unrecognized\" property (type unique_id, which has " ..
                          "no §4.6 row or DISPATCH entry) deliberately exercises " ..
                          "the unrecognized-property-type fallback, skipped with " ..
                          "a pandoc.log.info rather than a crash",

  ["meeting-notes.json"] = "transcription reads into the same Div class as " ..
                           "meeting_notes (design doc 4.3), so it writes back " ..
                           "out as meeting_notes",
  ["coalescing.json"]    = "adjacent runs sharing an identity are coalesced on " ..
                           "read by design (design doc 4.4); the merged run " ..
                           "count differs from the original's four runs",
  ["links.json"]         = "a run supplying href without text.link is " ..
                           "normalized on write to carry both, since the " ..
                           "AST -> JSON direction collapses many encodings " ..
                           "into one (design doc 2.7)",
  ["unknown-type.json"]  = "an unrecognized block type degrades to a visible " ..
                           "unknown block rather than vanishing or crashing " ..
                           "(design doc 6.4)",
  ["missing-payload.json"] = "a block whose payload key is genuinely absent " ..
                             "still occupies its position: it comes back as an " ..
                             "empty block of its declared type, with a " ..
                             "pandoc.log.warn so the recovery isn't silent " ..
                             "(design doc 6.5)",
}

local function basename(path) return path:match("([^/\\]+)$") end

for _, subdir in ipairs({ "blocks", "inlines", "properties",
                          "unhydrated", "adversarial" }) do
  for _, path in ipairs(bj.list(subdir)) do
    local name     = basename(path)
    local original = bj.read_file(path)

    local once  = bj.to_json(original)
    local twice = bj.to_json(once)

    -- The primary gate: stability. f(f(x)) == f(x).
    t.eq(twice, once, subdir .. "/" .. name .. " round-trips stably")

    -- The stronger additional check, where it is expected to hold.
    if not KNOWN_NOT_BYTE_IDENTICAL[name] then
      -- Compare structurally rather than by bytes, so insignificant whitespace
      -- in the hand-authored fixture does not count as a difference.
      t.eq(pandoc.json.decode(once), pandoc.json.decode(original),
           subdir .. "/" .. name .. " round-trips without loss")
    end
  end
end

-- Design doc 9.7: array discipline. Every key Notion specifies as an array must
-- serialize as one. A bare {} here is the failure this check exists to catch.
local ARRAY_KEYS = { rich_text = true, children = true, cells = true,
                     caption = true, results = true }

local function check_arrays(value, path, label)
  if type(value) ~= "table" then return end
  for key, child in pairs(value) do
    local here = path .. "." .. tostring(key)
    if ARRAY_KEYS[key] then
      -- An empty Lua table is ambiguous, so re-encode and inspect the text.
      local encoded = pandoc.json.encode(child)
      t.truthy(encoded:sub(1, 1) == "[",
               label .. here .. " must encode as an array, got " .. encoded:sub(1, 12))
    end
    check_arrays(child, here, label)
  end
end

for _, subdir in ipairs({ "blocks", "inlines", "adversarial" }) do
  for _, path in ipairs(bj.list(subdir)) do
    local produced = pandoc.json.decode(bj.to_json(bj.read_file(path)))
    check_arrays(produced, "", basename(path) .. " ")
  end
end
