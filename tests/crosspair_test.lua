local t   = require "support.assert"
local nfm = require "support.nfm"
local bj  = require "support.blockjson"

-- The executable assertion that both pairs meet in ONE AST:
--
--   NFM -> AST -> JSON -> AST -> NFM   must equal   NFM -> AST -> NFM
--
-- If the two pairs ever disagree about a class name, an attribute spelling or
-- a colour form, this fails. It is what would have caught the _bg /
-- _background mismatch on its own.
--
-- It scans blocks/, inlines/ and nesting/ but deliberately NOT official/ --
-- those fixtures are transcribed verbatim from Notion's documentation and are
-- not ours to reformat, so only stability is asserted for them elsewhere
-- (NFM design doc 9.2).

-- Detours through block JSON that lose something NFM can express, each with a
-- documented reason. Anything not listed here must survive the detour intact.
local KNOWN_LOSSY_DETOUR = {
  -- Every entry here is NFM expressing something the Notion block API has no
  -- field for -- the mirror of the asymmetry design doc 4.3 documents in the
  -- other direction, where the API's type set is larger than NFM's. Each names
  -- the specific missing field, not "formatting differs".
  --
  -- This list started at 10 and is down to 6: the other four turned out to be
  -- defects rather than asymmetries (image URLs dropped, toggle titles demoted,
  -- child_page/child_database titles omitted, citations silently deleted), and
  -- two more were fixed afterwards -- date mentions now carry startTime and
  -- timeZone through the ISO string and the API's time_zone field, and
  -- <empty-block/> now maps to the empty paragraph that is its exact Notion
  -- equivalent. Prefer fixing to listing: an entry here is a claim that the
  -- loss is unavoidable, and four such claims were wrong.
  ["page-database.nfm"] =
    "child_page/child_database carry only `title`; NFM's url= and inline= have no API field",
  ["synced-block.nfm"] =
    "an ORIGINAL synced_block has synced_from:null and no url; NFM's url= has no API field",
  ["unknown-block.nfm"] =
    "`unsupported` carries only block_type; NFM's <unknown url=> has no API field",
  ["image-attributes.nfm"] =
    "Notion's image block has no color field; NFM's {color=} has nowhere to go",
  ["emoji.nfm"] =
    "Notion stores the emoji character, not the :shortcode:, so it returns as the character",
  ["citation.nfm"] =
    "Notion has no citation construct; [^URL] degrades to a link on the URL, preserving the source",
}

local function basename(path) return path:match("([^/\\]+)$") end

local checked, detoured = 0, 0

for _, subdir in ipairs({ "blocks", "inlines", "nesting" }) do
  for _, path in ipairs(nfm.list(subdir)) do
    local name   = basename(path)
    local source = nfm.read_file(path)

    local direct   = nfm.to_nfm(source)              -- NFM -> AST -> NFM
    local via_json = bj.to_nfm(bj.from_nfm(source))  -- NFM -> AST -> JSON -> AST -> NFM

    checked = checked + 1
    if KNOWN_LOSSY_DETOUR[name] then
      detoured = detoured + 1
      -- Still assert stability through the detour, just not equality.
      t.eq(bj.to_nfm(bj.from_nfm(via_json)), via_json,
           subdir .. "/" .. name .. " is stable through the JSON detour")
    else
      t.eq(via_json, direct,
           subdir .. "/" .. name .. " survives the JSON detour unchanged")
    end
  end
end

-- nfm.list() returns an empty table for a missing or misnamed directory, so a
-- vanished corpus would make every loop above pass vacuously. Assert the count.
t.eq(checked, 39, "every NFM fixture was detoured, checked " .. checked)
t.eq(detoured, 6, "the lossy-detour list did not grow silently, detoured " .. detoured)

-- The reverse direction: JSON -> AST -> NFM -> AST -> JSON. Asserted for
-- STABILITY only, never equality. NFM's vocabulary is strictly smaller than the
-- block API's, so bookmark, embed, breadcrumb and friends genuinely cannot
-- survive a detour through it -- that asymmetry is by design (design doc 4.3),
-- not a defect.

local json_checked = 0
for _, path in ipairs(bj.list("blocks")) do
  local source = bj.read_file(path)
  json_checked = json_checked + 1
  local detour = bj.from_nfm(bj.to_nfm(source))
  t.eq(bj.to_json(bj.from_nfm(bj.to_nfm(detour))), bj.to_json(detour),
       basename(path) .. " is stable through the NFM detour")
end
t.truthy(json_checked > 0, "the JSON blocks corpus was scanned, checked " .. json_checked)
