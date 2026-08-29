local t       = require "support.assert"
local inlines = require "notion.reader.inlines"
local tree    = require "notion.reader.tree"
local blocks  = require "notion.reader.blocks"

-- Count real pandoc.read invocations by wrapping it.
local real_read = pandoc.read
local calls = 0
local function counting(...) calls = calls + 1; return real_read(...) end

local doc = {}
for i = 1, 20 do doc[#doc + 1] = "Line number " .. i .. " with **bold**." end
local src = table.concat(doc, "\n")

-- Baseline: one read per line without priming.
inlines.reset()
pandoc.read = counting
calls = 0
blocks.convert(tree.parse(src))
local unbatched = calls
pandoc.read = real_read
t.truthy(unbatched >= 20, "unprimed parsing reads once per line, got " .. unbatched)

-- Primed: a single read for the whole document.
inlines.reset()
pandoc.read = counting
calls = 0
inlines.prime(doc)
local primed_reads = calls
blocks.convert(tree.parse(src))
local total = calls
pandoc.read = real_read
t.eq(primed_reads, 1, "prime() makes exactly one pandoc.read call")
t.eq(total, 1, "no further reads are needed after priming")

-- Output is IDENTICAL either way. This is the assertion that matters.
inlines.reset()
local plain = pandoc.write(pandoc.Pandoc(blocks.convert(tree.parse(src))), "native")
inlines.reset()
inlines.prime(doc)
local batched = pandoc.write(pandoc.Pandoc(blocks.convert(tree.parse(src))), "native")
t.eq(batched, plain, "batching changes nothing about the output")

-- convert_document goes through the same primed path and produces the same
-- output as the unprimed convert() call above.
inlines.reset()
local via_entry = pandoc.write(pandoc.Pandoc(blocks.convert_document(tree.parse(src))), "native")
t.eq(via_entry, plain, "convert_document produces identical output to unprimed convert")

-- convert_document actually collapses to a single pandoc.read call for this
-- document (proving the batching wiring, not just prime() in isolation).
inlines.reset()
pandoc.read = counting
calls = 0
blocks.convert_document(tree.parse(src))
local entry_calls = calls
pandoc.read = real_read
t.eq(entry_calls, 1, "convert_document makes exactly one pandoc.read call")

-- Fallback: a chunk that pandoc splits into more than one block must not
-- corrupt the cache. "# not a heading here" would become a Header if the
-- joined batch were misparsed.
inlines.reset()
local tricky = { "plain one", "> quoted looking", "plain two" }
inlines.prime(tricky)
for _, text in ipairs(tricky) do
  local got = pandoc.write(pandoc.Pandoc({ pandoc.Plain(inlines.read(text)) }), "native")
  local want = pandoc.write(pandoc.Pandoc({ pandoc.Plain(
    (function() inlines.reset(); return inlines.read(text) end)()) }), "native")
  t.eq(got, want, "primed and unprimed agree for: " .. text)
end

-- The fallback path is actually exercised: joining these three texts with
-- "\n\n" makes pandoc parse "> quoted looking" as a BlockQuote, which
-- contains no "> quoted looking" leaf as blocks[2].content -- but crucially
-- the batch is NOT globally discarded here (each block position still lines
-- up 1:1 with a chunk), so this exercises the per-block `block.content`
-- guard rather than the whole-batch block-count guard. Confirm that guard
-- actually fires: after priming, the BlockQuote chunk must still be a cache
-- miss (prime() could not have cached a Plain/Para content for it).
do
  inlines.reset()
  inlines.prime(tricky)
  -- Reading the quoted chunk after priming must still produce the correct
  -- parse (a literal "> quoted looking" paragraph, per NFM's inline-level
  -- treatment) rather than something a corrupted cache entry would produce.
  local got = pandoc.write(pandoc.Pandoc({ pandoc.Plain(inlines.read("> quoted looking")) }), "native")
  inlines.reset()
  local want = pandoc.write(pandoc.Pandoc({ pandoc.Plain(inlines.read("> quoted looking")) }), "native")
  t.eq(got, want, "block-count-mismatched chunk falls back to a correct per-chunk read")
end

-- Whole-batch discard: construct a case where the TOTAL block count of the
-- joined document does not equal the chunk count, so M.prime's top-level
-- guard discards the entire batch. A blank-looking chunk ("") contributes
-- zero blocks when joined with "\n\n", desynchronizing the count.
do
  inlines.reset()
  local mismatched = { "alpha **bold**", "", "gamma *em*" }
  inlines.prime(mismatched)
  for _, text in ipairs(mismatched) do
    local got = pandoc.write(pandoc.Pandoc({ pandoc.Plain(inlines.read(text)) }), "native")
    inlines.reset()
    local want = pandoc.write(pandoc.Pandoc({ pandoc.Plain(inlines.read(text)) }), "native")
    inlines.reset()
    inlines.prime(mismatched)
    t.eq(got, want, "whole-batch mismatch falls back correctly for: " .. text)
  end
end

-- Chunks containing leading whitespace: prime() and read() must apply the
-- identical trim, or primed and unprimed results diverge (this is exactly
-- how markdown_strict's indented-code-block rule bit inline parsing before
-- the trim was added to M.read).
do
  inlines.reset()
  local indented = { "    **bold under four spaces**", "\tstill **bold**" }
  inlines.prime(indented)
  for _, text in ipairs(indented) do
    local got = pandoc.write(pandoc.Pandoc({ pandoc.Plain(inlines.read(text)) }), "native")
    inlines.reset()
    local want = pandoc.write(pandoc.Pandoc({ pandoc.Plain(inlines.read(text)) }), "native")
    inlines.reset()
    inlines.prime(indented)
    t.eq(got, want, "primed and unprimed agree on leading-whitespace chunk: " .. text)
    t.truthy(got:find("Strong", 1, true) ~= nil,
             "leading whitespace does not survive as a Code span: " .. text)
  end
end
