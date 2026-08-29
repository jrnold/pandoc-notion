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

-- gather()'s priming keys must match what block_for() actually looks up for
-- EVERY node kind, not just plain paragraphs -- headings, blockquotes, list
-- items/todos, and mixed documents all strip a prefix before calling
-- inlines.read, and gather() must strip the identical prefix or these node
-- kinds silently fall back to one pandoc.read per line, defeating the
-- batching (previously measured: a heading-only document made MORE calls
-- batched than unbatched, a net pessimization).
local function count_reads(src)
  inlines.reset()
  pandoc.read = counting
  calls = 0
  blocks.convert_document(tree.parse(src))
  local n = calls
  pandoc.read = real_read
  return n
end

local function assert_one_read_and_identical_output(src, label)
  t.eq(count_reads(src), 1, label .. ": convert_document makes exactly one pandoc.read call")
  inlines.reset()
  local unbatched = pandoc.write(pandoc.Pandoc(blocks.convert(tree.parse(src))), "native")
  inlines.reset()
  local batched = pandoc.write(pandoc.Pandoc(blocks.convert_document(tree.parse(src))), "native")
  t.eq(batched, unbatched, label .. ": batched and unbatched output are identical")
end

do
  local headings = {}
  for i = 1, 10 do headings[#headings + 1] = "# Heading " .. i end
  assert_one_read_and_identical_output(table.concat(headings, "\n"), "10 headings")
end

do
  local quotes = {}
  for i = 1, 10 do quotes[#quotes + 1] = "> Quote " .. i end
  assert_one_read_and_identical_output(table.concat(quotes, "\n"), "10 blockquotes")
end

do
  -- Headings, quotes, paragraphs, bullet/ordered items and to-dos, mixed in
  -- one document.
  local mixed = table.concat({
    "# Title",
    "A plain paragraph.",
    "> A quote",
    "- bullet one",
    "- bullet two",
    "1. ordered one",
    "- [ ] todo one",
    "- [x] todo two",
    "## Subheading",
    "Another paragraph.",
  }, "\n")
  assert_one_read_and_identical_output(mixed, "mixed headings/quotes/paragraphs/lists/todos")
end

do
  -- A code block and display math never reach inlines.read at all, so they
  -- must contribute zero reads and must not break the batch for the
  -- surrounding paragraphs.
  local src = table.concat({
    "Paragraph one.",
    "```",
    "code here",
    "```",
    "$$x^2$$",
    "Paragraph two.",
  }, "\n")
  assert_one_read_and_identical_output(src, "code block + display math + paragraphs")
end

-- A real <table>'s cells are context-dependent (see cell_text in blocks.lua):
-- <td> outside a <table> must read like ordinary text, so it cannot be
-- covered by leaf_text() the way every other tag is. Confirm the carve-out
-- didn't cost the batching win for actual tables, and that a stray <td>
-- outside a table no longer crashes or silently changes output (this was
-- CRITICAL 1 and CRITICAL 2 from the review of the first leaf_text cut).
do
  local tbl = table.concat({
    "<table header-row=\"true\">",
    "\t<tr>",
    "\t\t<td>Name</td>",
    "\t\t<td>Score</td>",
    "\t</tr>",
    "\t<tr>",
    "\t\t<td>Alice **bold**</td>",
    "\t\t<td>1</td>",
    "\t</tr>",
    "\t<tr>",
    "\t\t<td>Bob</td>",
    "\t\t<td>2 *em*</td>",
    "\t</tr>",
    "</table>",
  }, "\n")
  assert_one_read_and_identical_output(tbl, "table with 6 cells")

  -- Multi-line (tag_open) td cell: its content is a CHILD node read through
  -- the ordinary leaf_text/paragraph path, not cell_text -- confirm that
  -- also still batches and matches.
  local tbl_multiline = table.concat({
    "<table>",
    "\t<tr>",
    "\t\t<td>",
    "\t\t\tWrapped **cell** text",
    "\t\t</td>",
    "\t</tr>",
    "</table>",
  }, "\n")
  assert_one_read_and_identical_output(tbl_multiline, "table with multi-line td cell")
end

do
  -- Stray <td>, <td/>, <tr>, <colgroup>, <col> OUTSIDE a <table> are not
  -- cells/rows/columns at all -- schema.TABLE_TAGS membership alone doesn't
  -- make them one, only actually being walked as part of a real <table> by
  -- table_block()/gather()'s table-aware branch does. Each must read as
  -- ordinary literal text (block_for()'s own fallthrough for any
  -- unrecognised-in-context tag), not crash, and not have its tag
  -- wrapper stripped -- and gather() priming must not change that.
  local stray_tags = {
    "<td/>",
    "<tr>Loose row text</tr>",
    "<colgroup></colgroup>",
    "<col/>",
  }
  for _, tag_line in ipairs(stray_tags) do
    local src = table.concat({ "Before", tag_line, "After" }, "\n")
    assert_one_read_and_identical_output(src, "stray " .. tag_line .. " outside a table")
  end

  -- Multi-line stray <td> (tag_open, with children) must parse without
  -- error and keep its literal "<td>" tag text, exactly as before the
  -- leaf_text refactor -- this is the exact CRITICAL 1 crash reproduction.
  local stray_block_td = table.concat({ "Before", "<td>", "\tCell", "</td>", "After" }, "\n")
  assert_one_read_and_identical_output(stray_block_td, "stray block <td> outside a table")
  inlines.reset()
  local native = pandoc.write(pandoc.Pandoc(blocks.convert_document(tree.parse(stray_block_td))), "native")
  t.truthy(native:find('Str "<td>"', 1, true) ~= nil,
           "stray block <td>'s opening tag survives as literal text, not stripped: " .. native)

  -- Stray inline <td>Cell **b**</td> must keep the tag wrapper AND not
  -- re-parse "**b**" as Strong -- this is the exact CRITICAL 2 output-
  -- change reproduction (the buggy leaf_text stripped the tags and
  -- re-parsed the inner markdown).
  local stray_inline_td = table.concat({ "Before", "<td>Cell **b**</td>", "After" }, "\n")
  assert_one_read_and_identical_output(stray_inline_td, "stray inline <td> outside a table")
  inlines.reset()
  local inline_native =
    pandoc.write(pandoc.Pandoc(blocks.convert_document(tree.parse(stray_inline_td))), "native")
  t.truthy(inline_native:find('Str "<td>Cell **b**</td>"', 1, true) ~= nil,
           "stray inline <td> keeps its literal tag text and inner markdown unparsed: " .. inline_native)
end

-- inlines.read()'s cache must not hand back an aliased mutable object: two
-- reads of identical text sharing a cache entry must be distinct tables, or
-- a future in-place mutation at one call site would corrupt every other
-- occurrence of that line.
do
  inlines.reset()
  inlines.prime({ "shared text" })
  local a = inlines.read("shared text")
  local b = inlines.read("shared text")
  t.truthy(not rawequal(a, b), "two reads of the same primed text return distinct (unaliased) tables")
  t.eq(pandoc.write(pandoc.Pandoc({ pandoc.Plain(a) }), "native"),
       pandoc.write(pandoc.Pandoc({ pandoc.Plain(b) }), "native"),
       "the two distinct tables still have identical content")
end

-- A blank leaf_text (a bare "# ", a bare ">", "<td></td>") parses to ZERO
-- blocks once joined into the batch, which used to desync M.prime's
-- #doc.blocks ~= #texts guard and discard the WHOLE batch -- one wasted
-- priming read plus one per-chunk read for every other line in the
-- document (measured before this fix: "# \nPara." took 3 pandoc.read calls,
-- "Para one.\n> \nPara two." took 4). gather() now drops blank chunks
-- before they ever reach prime(), and M.read short-circuits blank text
-- without spending a pandoc.read call to confirm what is already known --
-- together the whole document, blank line included, must still batch to
-- exactly ONE read.
do
  local blanky = {
    "# \nPara.",
    "Para one.\n> \nPara two.",
    "<td></td>\nAfter.",
  }
  for _, src in ipairs(blanky) do
    assert_one_read_and_identical_output(src, "blank chunk alongside normal lines: " .. src)
  end
end

-- Item B confirmation: gather() must not prime a chunk nothing will ever
-- look up. Inside a real <table>, only cell text is requested (table_block
-- reads cells alone) -- <tr>, <colgroup>, and <col> are structural and are
-- never handed to inlines.read, so they must never appear in the joined
-- priming batch even though they are valid, non-blank strings. Capture the
-- exact text handed to the priming pandoc.read call and check.
do
  local tbl_colgroup = table.concat({
    "<table>",
    "\t<colgroup>",
    '\t\t<col color="blue"/>',
    "\t\t<col/>",
    "\t</colgroup>",
    "\t<tr>",
    "\t\t<td>A</td>",
    "\t\t<td>B</td>",
    "\t</tr>",
    "</table>",
  }, "\n")

  local real_read2 = pandoc.read
  local captured = nil
  local function capturing(text, ...) captured = text; return real_read2(text, ...) end
  inlines.reset()
  pandoc.read = capturing
  blocks.convert_document(tree.parse(tbl_colgroup))
  pandoc.read = real_read2

  t.truthy(captured ~= nil, "table with colgroup still primes at least the cell texts")
  t.truthy(captured:find("<colgroup>", 1, true) == nil,
           "gather() does not prime the never-looked-up '<colgroup>' chunk")
  t.truthy(captured:find("<tr>", 1, true) == nil,
           "gather() does not prime the never-looked-up '<tr>' chunk")
  t.truthy(captured:find("<col", 1, true) == nil,
           "gather() does not prime the never-looked-up '<col.../>' chunk")

  assert_one_read_and_identical_output(tbl_colgroup, "table with colgroup")
end
