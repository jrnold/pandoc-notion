# Notion Flavored Markdown Reader/Writer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a pandoc custom Lua reader and writer that make Notion Flavored Markdown (NFM) a first-class pandoc format in both directions.

**Architecture:** The reader is a hybrid — a hand-written, line-based block scanner owns everything NFM changed (tab nesting, `{attr}` suffixes, a closed HTML tag set, single-newline block separation), while inline content is delegated to pandoc's own Haskell markdown reader via `pandoc.read` under a pinned extension set. The writer is its mirror: plain dispatch tables with explicit tab-depth threading (not `pandoc.scaffolding.Writer`, whose `pandoc.layout` nesting emits spaces). A single shared `notion/schema.lua` holds the AST convention so the two directions cannot drift.

**Tech Stack:** Lua 5.4 (pandoc's bundled interpreter), pandoc 3.10.2 custom reader/writer API, no external dependencies. Tests run via `pandoc lua tests/run.lua`.

**Spec:** `docs/superpowers/specs/2026-08-28-notion-flavored-markdown-design.md`

## Global Constraints

Every task's requirements implicitly include this section.

- **pandoc 3.10.2 or later**, Lua 5.4, `PANDOC_API_VERSION` 1.23.1.2. Re-verify spec §2 if the version moves.
- **Zero external dependencies.** No luarocks, no busted. The only interpreter is `pandoc lua`.
- **Indentation is literal tabs.** Never spaces, on read or write.
- **Block separator is a single `\n`.** Not a blank line. Blank lines are stripped on read.
- **Escape set** (outside code blocks only): `\` `*` `~` `` ` `` `$` `[` `]` `<` `>` `{` `}` `|` `^`
- **Code block content is literal.** No escaping, no indent arithmetic, no attribute peeling inside a fence.
- **18 legal colors:** `gray` `brown` `orange` `yellow` `green` `blue` `purple` `pink` `red`, each also with a `_bg` suffix.
- **Pinned reader extension set**, used for every `pandoc.read` call:
  `markdown_strict+strikeout+tex_math_dollars+backtick_code_blocks+pipe_tables+task_lists+emoji+raw_html+all_symbols_escapable`
- **Structural representation only.** Notion constructs become `Div`/`Span` with classes and attributes. Never `RawBlock`/`RawInline`.
- **Attribute order is preserved, not canonicalized.** Verified: pandoc's `AttributeList` preserves insertion order under both `pairs()` and `ipairs()`. Preserving source order is what makes byte-exact round-trip achievable.
- **Degradation is silent** at default verbosity. `pandoc.log.info` only when content is genuinely dropped.
- **Commit after every task.** Conventional commit format (`feat:`, `test:`, `fix:`, `docs:`).

## File Structure

```
notion-markdown-reader.lua     entry: Reader(input, opts) — prelude + wiring only
notion-markdown-writer.lua     entry: Writer(doc, opts)   — prelude + wiring only
notion/
  schema.lua        SHARED: tag vocabulary and AST convention, one table
  attr.lua          SHARED: {key="value"} parse/serialize, color validation
  escape.lua        SHARED: the escape set
  reader/tree.lua   text → tab-indented node tree (no pandoc types)
  reader/blocks.lua node tree → pandoc Blocks
  reader/inlines.lua RawInline folding → the AST convention
  writer/blocks.lua pandoc Blocks → NFM lines (owns indent depth)
  writer/inlines.lua pandoc Inlines → NFM text
tests/
  run.lua              test runner; lists suites explicitly
  support/assert.lua   assertion helpers with deep table comparison
  support/nfm.lua      helpers that shell out to pandoc via pandoc.pipe
  unit/*_test.lua      per-module unit suites
  corpus/**            NFM fixtures (round-trip + AST goldens)
  golden/**            expected .native output
  degrade/**           pandoc-side inputs exercising lossy fallbacks
```

**Task dependency order:** 1 → 2 → 3 are foundations. 4 → 5 → 6 → 7 build the reader. 8 → 9 build the writer. 10 → 13 are cross-cutting verification and require both directions.

---

### Task 1: Test harness and `notion/escape.lua`

The harness must exist before anything can be tested, and `escape.lua` is the smallest real module — self-contained, no dependencies, needed by both directions. Building them together means Task 1 ends with a genuinely passing test suite rather than a harness with nothing in it.

**Files:**
- Create: `tests/support/assert.lua`
- Create: `tests/run.lua`
- Create: `notion/escape.lua`
- Test: `tests/unit/escape_test.lua`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `tests/support/assert.lua` returns `{ eq(actual, expected, msg), truthy(v, msg), report() -> exit_code, passed, failed }`. `eq` does deep comparison of nested tables.
  - `notion/escape.lua` returns `{ SPECIAL: string[], escape(s) -> string, unescape(s) -> string, is_special(c) -> boolean }`.

- [ ] **Step 1: Write the assertion helper**

Create `tests/support/assert.lua`:

```lua
local M = { passed = 0, failed = 0, failures = {} }

-- Deterministic rendering used for deep comparison and for failure messages.
-- Array part is rendered in index order; hash part is sorted by key name.
local function fmt(v)
  if type(v) ~= "table" then return string.format("%q", tostring(v)) end
  local parts, n = {}, #v
  for i = 1, n do parts[#parts + 1] = fmt(v[i]) end
  local keys = {}
  for k in pairs(v) do
    local is_index = type(k) == "number" and k % 1 == 0 and k >= 1 and k <= n
    if not is_index then keys[#keys + 1] = k end
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do
    parts[#parts + 1] = string.format("%s=%s", tostring(k), fmt(v[k]))
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end
M.fmt = fmt

function M.eq(actual, expected, msg)
  local a, e = fmt(actual), fmt(expected)
  if a == e then
    M.passed = M.passed + 1
  else
    M.failed = M.failed + 1
    M.failures[#M.failures + 1] = string.format(
      "%s\n    expected: %s\n    actual:   %s", msg or "eq", e, a)
  end
end

function M.truthy(v, msg)
  if v then M.passed = M.passed + 1
  else
    M.failed = M.failed + 1
    M.failures[#M.failures + 1] = (msg or "truthy") .. "\n    got falsy"
  end
end

function M.report()
  for _, f in ipairs(M.failures) do io.stderr:write("FAIL: " .. f .. "\n") end
  io.write(string.format("%d passed, %d failed\n", M.passed, M.failed))
  return M.failed == 0 and 0 or 1
end

return M
```

- [ ] **Step 2: Write the test runner**

Create `tests/run.lua`. Suites are listed explicitly so runs are deterministic and a missing file is a loud error:

```lua
local dir = (arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/../?.lua;" .. dir .. "/?.lua;" .. package.path

local t = require "support.assert"

local suites = {
  "unit.escape_test",
}

for _, s in ipairs(suites) do require(s) end

os.exit(t.report())
```

- [ ] **Step 3: Write the failing test**

Create `tests/unit/escape_test.lua`:

```lua
local t = require "support.assert"
local escape = require "notion.escape"

t.eq(escape.escape("a*b"), "a\\*b", "escapes asterisk")
t.eq(escape.escape("^caret^"), "\\^caret\\^", "escapes caret")
t.eq(escape.escape("plain text"), "plain text", "leaves ordinary text alone")
t.eq(escape.escape("a\\b"), "a\\\\b", "escapes the backslash itself")

t.eq(escape.unescape("a\\*b"), "a*b", "unescapes asterisk")
t.eq(escape.unescape("a\\qb"), "a\\qb", "leaves non-special escapes intact")

-- Every character in the spec's set round-trips.
for _, c in ipairs(escape.SPECIAL) do
  t.eq(escape.unescape(escape.escape(c)), c, "round-trips " .. c)
  t.eq(escape.escape(c), "\\" .. c, "escapes " .. c)
end

t.eq(#escape.SPECIAL, 13, "the spec lists exactly 13 special characters")
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `pandoc lua tests/run.lua`
Expected: FAIL — `module 'notion.escape' not found`

- [ ] **Step 5: Write the implementation**

Create `notion/escape.lua`:

```lua
local M = {}

-- Escaped outside code blocks, per the NFM spec.
M.SPECIAL = { "\\", "*", "~", "`", "$", "[", "]", "<", ">", "{", "}", "|", "^" }

local set = {}
for _, c in ipairs(M.SPECIAL) do set[c] = true end

function M.is_special(c) return set[c] == true end

function M.escape(s)
  return (s:gsub(".", function(c)
    if set[c] then return "\\" .. c end
    return nil          -- nil leaves the character untouched
  end))
end

function M.unescape(s)
  return (s:gsub("\\(.)", function(c)
    if set[c] then return c end
    return nil          -- not a special character: keep the backslash
  end))
end

return M
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `pandoc lua tests/run.lua`
Expected: PASS — `24 passed, 0 failed`

- [ ] **Step 7: Commit**

```bash
git add tests/support/assert.lua tests/run.lua tests/unit/escape_test.lua notion/escape.lua
git commit -m "test: add dependency-free harness and NFM escaping"
```

---

### Task 2: `notion/attr.lua`

Parses and renders NFM's `{key="value"}` attribute lists, and validates colors. Both directions depend on it, and getting the peel logic wrong is how prose that merely *looks* like an attribute list gets silently eaten.

**Files:**
- Create: `notion/attr.lua`
- Modify: `tests/run.lua` (add `"unit.attr_test"` to `suites`)
- Test: `tests/unit/attr_test.lua`

**Interfaces:**
- Consumes: nothing.
- Produces: `notion/attr.lua` returning:
  - `COLORS` — set of the 18 legal color strings
  - `is_color(v) -> boolean`
  - `parse(body) -> {pairs}, {order}` — parses an attribute-list body, returning a key→value map and an array of key names in source order
  - `peel(line) -> text, pairs, order` — strips a trailing `{…}` from a line; returns the line unchanged with an empty table when there is none
  - `render(pairs, order) -> string` — renders ` {k="v" …}`, or `""` when empty
  - `ordered(pairs, order) -> {{k,v},…}` — an ordered array suitable for `pandoc.Attr`. **Required:** passing a plain Lua map to `pandoc.Attr` yields non-deterministic attribute order across runs, which makes byte-exact round-trip tests flaky.
  - `from_attr(attributes) -> pairs, order` — the inverse, reading a pandoc `AttributeList` in its preserved order

- [ ] **Step 1: Write the failing test**

Create `tests/unit/attr_test.lua`:

```lua
local t = require "support.assert"
local attr = require "notion.attr"

-- colors
t.truthy(attr.is_color("blue"), "blue is a color")
t.truthy(attr.is_color("blue_bg"), "blue_bg is a color")
t.truthy(not attr.is_color("chartreuse"), "chartreuse is not")
local n = 0
for _ in pairs(attr.COLORS) do n = n + 1 end
t.eq(n, 18, "exactly 18 legal colors")

-- parse keeps source order
local p, order = attr.parse('icon="X" color="blue_bg"')
t.eq(p, { icon = "X", color = "blue_bg" }, "parses both pairs")
t.eq(order, { "icon", "color" }, "records source order")

-- peel
local text, pairs_, ord = attr.peel('Rich text {color="blue"}')
t.eq(text, "Rich text", "peels the attribute list off")
t.eq(pairs_, { color = "blue" }, "returns the attributes")
t.eq(ord, { "color" }, "returns the order")

-- prose that merely looks like an attribute list must survive untouched
local t2, p2 = attr.peel("see the {color} field")
t.eq(t2, "see the {color} field", "no key=\"value\" means no attribute list")
t.eq(p2, {}, "and no attributes")

local t3, p3 = attr.peel('a literal brace \\{color="blue"}')
t.eq(t3, 'a literal brace \\{color="blue"}', "escaped brace is not an attribute list")
t.eq(p3, {}, "and yields no attributes")

local t4 = attr.peel("plain line")
t.eq(t4, "plain line", "line without braces is unchanged")

-- render
t.eq(attr.render({ color = "blue" }, { "color" }), ' {color="blue"}', "renders one pair")
t.eq(attr.render({ icon = "X", color = "b" }, { "icon", "color" }),
     ' {icon="X" color="b"}', "renders in the given order")
t.eq(attr.render({}, {}), "", "empty renders as empty string")

-- render round-trips peel, which is what byte-exact idempotence depends on
local line = 'Heading {icon="X" color="blue_bg"}'
local body, bp, bo = attr.peel(line)
t.eq(body .. attr.render(bp, bo), line, "peel then render is identity")

-- ordered() exists because pandoc.Attr given a plain Lua map produces a
-- DIFFERENT attribute order on every run, which would make round-trip tests
-- flaky rather than merely wrong.
t.eq(attr.ordered({ icon = "X", color = "b" }, { "icon", "color" }),
     { { "icon", "X" }, { "color", "b" } }, "ordered builds a {k,v} array")

local stable = {}
for i = 1, 5 do
  local a = pandoc.Attr("", {}, attr.ordered({ icon = "X", color = "b", url = "u" },
                                             { "icon", "color", "url" }))
  local keys = {}
  for _, kv in ipairs(a.attributes) do keys[#keys + 1] = kv[1] end
  stable[i] = table.concat(keys, ",")
end
t.eq(stable, { "icon,color,url", "icon,color,url", "icon,color,url",
               "icon,color,url", "icon,color,url" },
     "pandoc.Attr order is stable when given an ordered array")

-- from_attr reads a pandoc AttributeList back in its preserved order
local pa = pandoc.Attr("", {}, { { "icon", "X" }, { "color", "b" } })
local fp, fo = attr.from_attr(pa.attributes)
t.eq(fp, { icon = "X", color = "b" }, "from_attr recovers the pairs")
t.eq(fo, { "icon", "color" }, "from_attr recovers the order")
```

- [ ] **Step 2: Register the suite**

In `tests/run.lua`, extend `suites`:

```lua
local suites = {
  "unit.escape_test",
  "unit.attr_test",
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `pandoc lua tests/run.lua`
Expected: FAIL — `module 'notion.attr' not found`

- [ ] **Step 4: Write the implementation**

Create `notion/attr.lua`:

```lua
local M = {}

local BASE = { "gray", "brown", "orange", "yellow", "green",
               "blue", "purple", "pink", "red" }

M.COLORS = {}
for _, c in ipairs(BASE) do
  M.COLORS[c] = true
  M.COLORS[c .. "_bg"] = true
end

function M.is_color(v) return M.COLORS[v] == true end

-- Parse an attribute-list body (the text between the braces).
-- Returns a key->value map plus an array of keys in source order.
function M.parse(body)
  local out, order = {}, {}
  for k, v in body:gmatch('([%w_%-]+)%s*=%s*"([^"]*)"') do
    if out[k] == nil then order[#order + 1] = k end
    out[k] = v
  end
  return out, order
end

-- Strip a trailing {…} attribute list off a line.
-- Returns text, pairs, order. When there is no attribute list the line comes
-- back unchanged with empty tables.
function M.peel(line)
  local text, body = line:match('^(.-)%s*{(.-)}%s*$')
  if not body then return line, {}, {} end
  -- Require at least one key="value"; otherwise it is ordinary prose.
  if not body:match('[%w_%-]+%s*=%s*"') then return line, {}, {} end
  -- A backslash immediately before the brace escapes it.
  if text:sub(-1) == "\\" then return line, {}, {} end
  local pairs_, order = M.parse(body)
  return text, pairs_, order
end

-- Render ` {k="v" …}`. Keys in `order` come first, in that order; any
-- remaining keys follow, sorted, so output is always deterministic.
function M.render(pairs_, order)
  local seen, parts = {}, {}
  for _, k in ipairs(order or {}) do
    if pairs_[k] ~= nil and not seen[k] then
      seen[k] = true
      parts[#parts + 1] = string.format('%s="%s"', k, pairs_[k])
    end
  end
  local rest = {}
  for k in pairs(pairs_) do if not seen[k] then rest[#rest + 1] = k end end
  table.sort(rest)
  for _, k in ipairs(rest) do
    parts[#parts + 1] = string.format('%s="%s"', k, pairs_[k])
  end
  if #parts == 0 then return "" end
  return " {" .. table.concat(parts, " ") .. "}"
end

-- Build an ordered {{k,v},…} array for pandoc.Attr.
-- MUST be used instead of passing a plain map: pandoc.Attr given a map emits a
-- different attribute order on every run, which makes byte-exact round-trip
-- assertions flaky rather than deterministically wrong.
function M.ordered(pairs_, order)
  local seen, out = {}, {}
  for _, k in ipairs(order or {}) do
    if pairs_[k] ~= nil and not seen[k] then
      seen[k] = true
      out[#out + 1] = { k, pairs_[k] }
    end
  end
  local rest = {}
  for k in pairs(pairs_) do if not seen[k] then rest[#rest + 1] = k end end
  table.sort(rest)
  for _, k in ipairs(rest) do out[#out + 1] = { k, pairs_[k] } end
  return out
end

-- Read a pandoc AttributeList back into pairs plus order. AttributeList
-- preserves insertion order under ipairs, which is what makes byte-exact
-- round-trip achievable without imposing a canonical ordering.
function M.from_attr(attributes)
  local pairs_, order = {}, {}
  for _, kv in ipairs(attributes) do
    pairs_[kv[1]] = kv[2]
    order[#order + 1] = kv[1]
  end
  return pairs_, order
end

return M
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `pandoc lua tests/run.lua`
Expected: PASS — all escape and attr assertions green.

- [ ] **Step 6: Commit**

```bash
git add notion/attr.lua tests/unit/attr_test.lua tests/run.lua
git commit -m "feat: add NFM attribute list parsing and rendering"
```

---

### Task 3: `notion/schema.lua`

The shared source of truth for the AST convention. Both directions consult it, and the future block-JSON pair will target it. It is pure data plus reverse lookups — no logic — which is why it can be verified entirely by assertion.

**Files:**
- Create: `notion/schema.lua`
- Modify: `tests/run.lua`
- Test: `tests/unit/schema_test.lua`

**Interfaces:**
- Consumes: nothing.
- Produces: `notion/schema.lua` returning:
  - `CONTAINERS` — set of multi-line container tag names (nest by tag balance)
  - `BLOCK_TAGS` — `tag -> { class, attrs (ordered names), void (bool) }`
  - `MEDIA_TAGS` — `tag -> { class, attrs }`, rendered as `Figure`
  - `MENTION_TAGS` — `tag -> { class, attrs }`, rendered as `Span`
  - `class_to_tag(class) -> tag, kind` where `kind` is `"block"`, `"media"`, or `"mention"`
  - `is_known_tag(tag) -> boolean`

- [ ] **Step 1: Write the failing test**

Create `tests/unit/schema_test.lua`:

```lua
local t = require "support.assert"
local schema = require "notion.schema"

-- block tags carry class and ordered attribute names
t.eq(schema.BLOCK_TAGS.callout.class, "callout", "callout class")
t.eq(schema.BLOCK_TAGS.callout.attrs, { "icon", "color" }, "callout attr order")
t.eq(schema.BLOCK_TAGS.details.class, "toggle", "<details> maps to the toggle class")

-- the two tags absent from the enhanced-markdown page but required by real pages
t.eq(schema.BLOCK_TAGS.unknown.class, "unknown", "<unknown> is in the vocabulary")
t.eq(schema.BLOCK_TAGS.unknown.attrs, { "url", "alt" }, "unknown attr order")
t.truthy(schema.BLOCK_TAGS.unknown.void, "<unknown> is self-closing")
t.eq(schema.BLOCK_TAGS["meeting-notes"].class, "meeting-notes", "<meeting-notes> exists")

-- toggle and toggle-heading are distinct classes, never shared
t.truthy(schema.class_to_tag("toggle") == "details", "toggle class belongs to <details>")
t.truthy(schema.class_to_tag("toggle-heading") == nil,
         "toggle-heading has no tag; it is built from a Header")

-- media
t.eq(schema.MEDIA_TAGS.video.class, "video", "video class")
t.eq(schema.MEDIA_TAGS.video.attrs, { "src", "color" }, "video attr order")
for _, tag in ipairs({ "audio", "video", "file", "pdf" }) do
  t.truthy(schema.MEDIA_TAGS[tag], tag .. " is a media tag")
end

-- mentions: all six, each with both classes available via class_to_tag
for _, tag in ipairs({ "mention-user", "mention-page", "mention-database",
                       "mention-data-source", "mention-agent", "mention-date" }) do
  t.truthy(schema.MENTION_TAGS[tag], tag .. " is a mention tag")
end

-- containers nest by tag balance
for _, tag in ipairs({ "callout", "details", "columns", "column", "table",
                       "synced_block", "synced_block_reference", "meeting-notes" }) do
  t.truthy(schema.CONTAINERS[tag], tag .. " is a container")
end
t.truthy(not schema.CONTAINERS.unknown, "self-closing tags are not containers")
t.truthy(not schema.CONTAINERS.page, "single-line tags are not containers")

-- reverse lookup is total over every declared class
local _, kind = schema.class_to_tag("video")
t.eq(kind, "media", "video reverses to a media tag")
local _, kind2 = schema.class_to_tag("mention-user")
t.eq(kind2, "mention", "mention-user reverses to a mention tag")

t.truthy(schema.is_known_tag("callout"), "callout is known")
t.truthy(not schema.is_known_tag("marquee"), "marquee is not")
```

- [ ] **Step 2: Register the suite**

Add `"unit.schema_test"` to `suites` in `tests/run.lua`.

- [ ] **Step 3: Run the test to verify it fails**

Run: `pandoc lua tests/run.lua`
Expected: FAIL — `module 'notion.schema' not found`

- [ ] **Step 4: Write the implementation**

Create `notion/schema.lua`:

```lua
local M = {}

-- Multi-line containers: these nest by tag balance rather than by indentation.
M.CONTAINERS = {}
for _, tag in ipairs({ "callout", "details", "summary", "columns", "column",
                       "table", "colgroup", "tr", "synced_block",
                       "synced_block_reference", "meeting-notes" }) do
  M.CONTAINERS[tag] = true
end

-- tag -> Div class plus the attribute order used when rendering back to NFM.
M.BLOCK_TAGS = {
  callout                = { class = "callout",                attrs = { "icon", "color" } },
  details                = { class = "toggle",                 attrs = { "color" } },
  summary                = { class = "summary",                attrs = {} },
  columns                = { class = "columns",                attrs = {} },
  column                 = { class = "column",                 attrs = {} },
  synced_block           = { class = "synced-block",           attrs = { "url" } },
  synced_block_reference = { class = "synced-block-reference", attrs = { "url" } },
  ["meeting-notes"]      = { class = "meeting-notes",          attrs = {} },
  page                   = { class = "page",                   attrs = { "url", "color" } },
  database               = { class = "database",               attrs = { "url", "inline", "icon", "color" } },
  table_of_contents      = { class = "table-of-contents",      attrs = { "color" }, void = true },
  ["empty-block"]        = { class = "empty-block",            attrs = {},          void = true },
  unknown                = { class = "unknown",                attrs = { "url", "alt" }, void = true },
}

-- Media blocks render as Figure with a type class.
M.MEDIA_TAGS = {
  audio = { class = "audio", attrs = { "src", "color" } },
  video = { class = "video", attrs = { "src", "color" } },
  file  = { class = "file",  attrs = { "src", "color" } },
  pdf   = { class = "pdf",   attrs = { "src", "color" } },
}

-- Mentions render as Span with classes {"mention", "mention-<kind>"}.
M.MENTION_TAGS = {
  ["mention-user"]        = { class = "mention-user",        attrs = { "url" } },
  ["mention-page"]        = { class = "mention-page",        attrs = { "url" } },
  ["mention-database"]    = { class = "mention-database",    attrs = { "url" } },
  ["mention-data-source"] = { class = "mention-data-source", attrs = { "url" } },
  ["mention-agent"]       = { class = "mention-agent",       attrs = { "url" } },
  ["mention-date"]        = { class = "mention-date",
                              attrs = { "start", "end", "startTime", "timeZone" } },
}

-- Reverse lookups, built once at load.
local reverse = {}
for tag, def in pairs(M.BLOCK_TAGS)   do reverse[def.class] = { tag, "block"   } end
for tag, def in pairs(M.MEDIA_TAGS)   do reverse[def.class] = { tag, "media"   } end
for tag, def in pairs(M.MENTION_TAGS) do reverse[def.class] = { tag, "mention" } end

function M.class_to_tag(class)
  local hit = reverse[class]
  if not hit then return nil, nil end
  return hit[1], hit[2]
end

function M.is_known_tag(tag)
  return (M.BLOCK_TAGS[tag] or M.MEDIA_TAGS[tag] or M.MENTION_TAGS[tag]) ~= nil
end

return M
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `pandoc lua tests/run.lua`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add notion/schema.lua tests/unit/schema_test.lua tests/run.lua
git commit -m "feat: add shared NFM/pandoc AST convention schema"
```

---

### Task 4: `reader/tree.lua` pass 1 — line classification

The highest-risk logic in the project. Fence awareness must come first, because everything else (indent arithmetic, attribute peeling, tag detection) must be suppressed inside a code fence.

**Files:**
- Create: `notion/reader/tree.lua`
- Modify: `tests/run.lua`
- Test: `tests/unit/tree_classify_test.lua`

**Interfaces:**
- Consumes: `notion.schema` (`is_known_tag`, `CONTAINERS`).
- Produces: `notion/reader/tree.lua` with (pass 2 added in Task 5):
  - `lines(text) -> string[]` — splits on newlines, normalizing CRLF and CR, dropping one trailing newline
  - `classify(text) -> node[]` where each node is `{ kind, indent, text, tag? }` and `kind` is one of `fence_open`, `fence_body`, `fence_close`, `tag_open`, `tag_close`, `tag_inline`, `self_closing`, `text`, `blank`

- [ ] **Step 1: Write the failing test**

Create `tests/unit/tree_classify_test.lua`:

```lua
local t = require "support.assert"
local tree = require "notion.reader.tree"

local function kinds(text)
  local out = {}
  for _, n in ipairs(tree.classify(text)) do out[#out + 1] = n.kind end
  return out
end

-- line splitting normalizes line endings
t.eq(tree.lines("a\r\nb\rc\n"), { "a", "b", "c" }, "normalizes CRLF and CR, drops trailing newline")
t.eq(tree.lines("a\n\nb"), { "a", "", "b" }, "keeps interior blank lines")

-- single newline separates blocks: two text lines are two nodes
t.eq(kinds("one\ntwo"), { "text", "text" }, "adjacent lines are separate blocks")

-- indentation is counted in tabs, and stripped from the node text
local n = tree.classify("- parent\n\tchild")
t.eq(n[1].indent, 0, "parent at depth 0")
t.eq(n[2].indent, 1, "child at depth 1")
t.eq(n[2].text, "child", "indent is stripped from text")

-- leading spaces are NOT indentation
local sp = tree.classify("  spaced")
t.eq(sp[1].indent, 0, "spaces do not create depth")
t.eq(sp[1].text, "  spaced", "and are left in the text")

-- fences: content is literal, and NFM syntax inside must not be classified
local fenced = tree.classify("```lua\n<callout icon=\"X\">\n- a\n```")
t.eq(kinds("```lua\n<callout icon=\"X\">\n- a\n```"),
     { "fence_open", "fence_body", "fence_body", "fence_close" },
     "fence body is never interpreted")
t.eq(fenced[1].text, "lua", "fence_open carries the info string")
t.eq(fenced[2].text, '<callout icon="X">', "tag inside a fence stays literal")

-- a tab-indented fence keeps its body verbatim relative to the fence indent
local ind = tree.classify("\t```\n\tcode\n\t```")
t.eq(ind[2].text, "code", "fence body is de-indented by the fence's own depth")

-- tags
t.eq(kinds('<callout icon="X">'), { "tag_open" }, "opening container tag")
t.eq(kinds("</callout>"), { "tag_close" }, "closing tag")
t.eq(kinds("<table_of_contents/>"), { "self_closing" }, "self-closing tag")
t.eq(kinds('<unknown url="u" alt="bookmark"/>'), { "self_closing" }, "unknown block tag")
t.eq(kinds('<page url="u">Title</page>'), { "tag_inline" }, "tag opening and closing on one line")

-- unknown tags are literal text, never tags
t.eq(kinds("<marquee>hi</marquee>"), { "text" }, "tags outside the vocabulary are text")

-- blanks
t.eq(kinds("a\n\nb"), { "text", "blank", "text" }, "blank lines are classified, stripped later")

local nodes = tree.classify('<callout icon="X">')
t.eq(nodes[1].tag, "callout", "tag name is recorded")
```

- [ ] **Step 2: Register the suite**

Add `"unit.tree_classify_test"` to `suites` in `tests/run.lua`.

- [ ] **Step 3: Run the test to verify it fails**

Run: `pandoc lua tests/run.lua`
Expected: FAIL — `module 'notion.reader.tree' not found`

- [ ] **Step 4: Write the implementation**

Create `notion/reader/tree.lua`:

```lua
local schema = require "notion.schema"

local M = {}

function M.lines(text)
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n$", "")
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
  return out
end

-- Depth is a count of leading TABS only. Spaces are never indentation.
local function split_indent(line)
  local tabs = line:match("^\t*")
  return #tabs, line:sub(#tabs + 1)
end

-- Classify a non-fence line that starts with '<'. Returns kind, tag or nil.
local function tag_kind(body)
  local closing = body:match("^</([%w_%-]+)>%s*$")
  if closing then
    if not schema.is_known_tag(closing) then return nil end
    return "tag_close", closing
  end
  local tag = body:match("^<([%w_%-]+)[%s/>]")
  if not tag or not schema.is_known_tag(tag) then return nil end
  if body:match("/>%s*$") then return "self_closing", tag end
  if body:match("</" .. tag .. ">%s*$") then return "tag_inline", tag end
  return "tag_open", tag
end

function M.classify(text)
  local out, fence = {}, nil
  for _, raw in ipairs(M.lines(text)) do
    local depth, body = split_indent(raw)
    if fence then
      local close = body:match("^(`+)%s*$")
      if close and #close >= #fence.marker then
        out[#out + 1] = { kind = "fence_close", indent = fence.indent, text = "" }
        fence = nil
      else
        -- Literal: strip only the fence's own indentation, interpret nothing.
        out[#out + 1] = { kind = "fence_body", indent = fence.indent,
                          text = raw:sub(fence.indent + 1) }
      end
    else
      local marker, info = body:match("^(```+)%s*(.-)%s*$")
      if marker then
        fence = { marker = marker, indent = depth }
        out[#out + 1] = { kind = "fence_open", indent = depth, text = info }
      elseif body == "" then
        out[#out + 1] = { kind = "blank", indent = depth, text = "" }
      else
        local kind, tag = tag_kind(body)
        out[#out + 1] = { kind = kind or "text", tag = tag,
                          indent = depth, text = body }
      end
    end
  end
  return out
end

return M
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `pandoc lua tests/run.lua`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add notion/reader/tree.lua tests/unit/tree_classify_test.lua tests/run.lua
git commit -m "feat: add fence-aware NFM line classification"
```

---

### Task 5: `reader/tree.lua` pass 2 — nesting

Turns the flat classified list into a tree. Two nesting mechanisms coexist: tab depth for markdown-ish blocks, tag balance for multi-line containers.

**Files:**
- Modify: `notion/reader/tree.lua`
- Modify: `tests/run.lua`
- Test: `tests/unit/tree_nest_test.lua`

**Interfaces:**
- Consumes: `notion.attr` (`peel`), the Task 4 `classify`.
- Produces: `tree.parse(text) -> node[]`, a tree where each node is
  `{ kind, text, tag?, attrs, attr_order, children }`. Blank nodes are removed.
  Fence runs are collapsed into a single `{ kind = "code", info, text }` node
  whose `text` is the joined literal body.

- [ ] **Step 1: Write the failing test**

Create `tests/unit/tree_nest_test.lua`:

```lua
local t = require "support.assert"
local tree = require "notion.reader.tree"

-- indentation nesting
local n = tree.parse("- parent\n\tchild\n\t\tgrandchild")
t.eq(#n, 1, "one root")
t.eq(n[1].text, "- parent", "root text")
t.eq(#n[1].children, 1, "one child")
t.eq(n[1].children[1].text, "child", "child text")
t.eq(n[1].children[1].children[1].text, "grandchild", "grandchild nests")

-- siblings at depth 0 are separate blocks (single-newline rule)
local sib = tree.parse("one\ntwo\nthree")
t.eq(#sib, 3, "three sibling blocks")

-- blank lines are stripped entirely
t.eq(#tree.parse("a\n\n\nb"), 2, "blank lines vanish")

-- attributes are peeled during nesting
local a = tree.parse('Rich text {color="blue"}')
t.eq(a[1].text, "Rich text", "attribute list removed from text")
t.eq(a[1].attrs, { color = "blue" }, "attributes captured")
t.eq(a[1].attr_order, { "color" }, "order captured")

-- tag balance nesting, independent of indentation
local c = tree.parse('<callout icon="X" color="blue_bg">\n\tRich **text**\n</callout>')
t.eq(#c, 1, "callout is one root node")
t.eq(c[1].tag, "callout", "tag recorded")
t.eq(c[1].attrs, { icon = "X", color = "blue_bg" }, "tag attributes parsed")
t.eq(#c[1].children, 1, "one child")
t.eq(c[1].children[1].text, "Rich **text**", "child content")

-- Notion's own docs indent container children with SPACES; tag balance means
-- that still works, because indentation is not what nests them.
local sp = tree.parse('<callout icon="X">\n    Spaced child\n</callout>')
t.eq(#sp[1].children, 1, "space-indented container child still nests")
t.eq(sp[1].children[1].text, "Spaced child", "and keeps its text")

-- fences collapse into one code node with literal content
local f = tree.parse("```python\ndef f():\n\treturn 1\n```")
t.eq(#f, 1, "fence is one node")
t.eq(f[1].kind, "code", "kind is code")
t.eq(f[1].info, "python", "language captured")
t.eq(f[1].text, "def f():\n\treturn 1", "body is literal, tabs preserved")

-- unbalanced closing tag is recovered as literal text, never fatal
local u = tree.parse("</callout>")
t.eq(#u, 1, "recovered as one node")
t.eq(u[1].kind, "text", "treated as literal text")
t.eq(u[1].text, "</callout>", "text preserved verbatim")

-- self-closing tags are complete nodes and open no nesting level
local v = tree.parse("<table_of_contents/>\nafter")
t.eq(#v, 2, "self-closing tag does not swallow the next line")
t.eq(v[1].tag, "table_of_contents", "tag recorded")
t.eq(#v[1].children, 0, "and has no children")
```

- [ ] **Step 2: Register the suite**

Add `"unit.tree_nest_test"` to `suites` in `tests/run.lua`.

- [ ] **Step 3: Run the test to verify it fails**

Run: `pandoc lua tests/run.lua`
Expected: FAIL — `attempt to call a nil value (field 'parse')`

- [ ] **Step 4: Write the implementation**

Append to `notion/reader/tree.lua`, before the final `return M`:

```lua
local attr = require "notion.attr"

-- Collapse fence runs into single `code` nodes and drop blanks.
local function collapse(nodes)
  local out, i = {}, 1
  while i <= #nodes do
    local n = nodes[i]
    if n.kind == "fence_open" then
      local body, j = {}, i + 1
      while j <= #nodes and nodes[j].kind == "fence_body" do
        body[#body + 1] = nodes[j].text
        j = j + 1
      end
      out[#out + 1] = { kind = "code", indent = n.indent, info = n.text,
                        text = table.concat(body, "\n"),
                        attrs = {}, attr_order = {}, children = {} }
      -- skip the closing fence when present; an unterminated fence just ends
      if j <= #nodes and nodes[j].kind == "fence_close" then j = j + 1 end
      i = j
    elseif n.kind == "blank" then
      i = i + 1
    else
      out[#out + 1] = n
      i = i + 1
    end
  end
  return out
end

-- Build the tree. `stack` holds open containers; indentation nests everything
-- else. Returns the roots.
function M.parse(text)
  local nodes = collapse(M.classify(text))
  local roots = {}
  local open = {}          -- open tag containers, innermost last

  local function current_children()
    if #open > 0 then return open[#open].children end
    return roots
  end

  -- Attach `node` by indentation within `list`, descending into the last
  -- sibling chain until the depth matches.
  local function attach(list, node, depth)
    local target, level = list, 0
    while level < depth and #target > 0 do
      target = target[#target].children
      level = level + 1
    end
    target[#target + 1] = node
  end

  local base_depth = {}    -- indent depth at which each open container started

  for _, n in ipairs(nodes) do
    if n.kind == "tag_close" then
      if #open > 0 and open[#open].tag == n.tag then
        table.remove(open)
        table.remove(base_depth)
      else
        -- Unbalanced: recover as literal text.
        attach(current_children(),
               { kind = "text", text = n.text ~= "" and n.text or ("</" .. n.tag .. ">"),
                 attrs = {}, attr_order = {}, children = {} },
               0)
      end
    else
      local text, attrs, order
      if n.kind == "code" then
        text, attrs, order = n.text, {}, {}
      elseif n.kind == "tag_open" or n.kind == "self_closing" or n.kind == "tag_inline" then
        local body = n.text:match("^<[%w_%-]+%s*(.-)%s*/?>") or ""
        attrs, order = attr.parse(body)
        text = n.text
      else
        text, attrs, order = attr.peel(n.text)
      end

      local node = { kind = n.kind, tag = n.tag, info = n.info, text = text,
                     attrs = attrs, attr_order = order, children = {} }

      -- Inside a tag container, indentation is cosmetic: attach directly.
      if #open > 0 then
        local rel = n.indent - base_depth[#base_depth] - 1
        attach(open[#open].children, node, rel > 0 and rel or 0)
      else
        attach(roots, node, n.indent)
      end

      if n.kind == "tag_open" then
        open[#open + 1] = node
        base_depth[#base_depth + 1] = n.indent
      end
    end
  end

  return roots
end
```

Note the `tag_close` recovery path reconstructs the literal text, because
`classify` sets `text` to the full line for tag nodes.

- [ ] **Step 5: Run the test to verify it passes**

Run: `pandoc lua tests/run.lua`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add notion/reader/tree.lua tests/unit/tree_nest_test.lua tests/run.lua
git commit -m "feat: nest NFM blocks by tab depth and tag balance"
```

---

### Task 6: `reader/inlines.lua`

Folds the balanced `RawInline "html"` pairs that the pinned extension set produces into the AST convention, and handles the two syntaxes pandoc leaves literal.

**Files:**
- Create: `notion/reader/inlines.lua`
- Modify: `tests/run.lua`
- Test: `tests/unit/reader_inlines_test.lua`

**Interfaces:**
- Consumes: `notion.schema`, `notion.attr`.
- Produces: `notion/reader/inlines.lua` returning:
  - `EXTENSIONS` — the pinned format string used for every `pandoc.read`
  - `read(text) -> Inlines` — parses one line of NFM inline content
  - `fold(inlines) -> Inlines` — folds raw HTML pairs into the convention

- [ ] **Step 1: Write the failing test**

Create `tests/unit/reader_inlines_test.lua`:

```lua
local t = require "support.assert"
local inlines = require "notion.reader.inlines"

local function render(ils)
  return pandoc.write(pandoc.Pandoc({ pandoc.Plain(ils) }), "native")
end
local function has(ils, needle, msg)
  t.truthy(render(ils):find(needle, 1, true) ~= nil, msg)
end

-- the pinned extension set must not fabricate constructs NFM lacks
local lit = inlines.read("~sub~ and H~2~O and @citekey")
t.truthy(render(lit):find("Subscript") == nil, "no Subscript fabricated")
t.truthy(render(lit):find("Cite") == nil, "no Cite fabricated")

-- native markdown still works
has(inlines.read("**b** and *i* and `c`"), "Strong", "bold parses")
has(inlines.read("**b** and *i* and `c`"), "Emph", "italic parses")
has(inlines.read("[t](http://x)"), "Link", "links parse")
has(inlines.read("$e=mc^2$"), "Math InlineMath", "inline math parses")
has(inlines.read("~~gone~~"), "Strikeout", "strikeout parses")

-- NFM tags fold into the convention
has(inlines.read('<span underline="true">u</span>'), "Underline",
    "underline becomes the native Underline node")
has(inlines.read('<span color="red">c</span>'), '"color" , "red"',
    "inline color becomes a Span attribute")
has(inlines.read('<mention-user url="u://1">Ada</mention-user>'), '"mention"',
    "mention carries the generic class")
has(inlines.read('<mention-user url="u://1">Ada</mention-user>'), '"mention-user"',
    "mention carries the specific class")
has(inlines.read('<mention-user url="u://1">Ada</mention-user>'), "Ada",
    "mention keeps its label")
has(inlines.read('<mention-date start="2026-01-01"/>'), '"mention-date"',
    "self-closing mention folds")
has(inlines.read("a<br>b"), "LineBreak", "<br> becomes LineBreak")

-- citation is a Span with a url attribute, never a Cite
local cit = inlines.read("[^https://x.com/a]")
has(cit, '"citation"', "citation class applied")
has(cit, "https://x.com/a", "citation url captured")
t.truthy(render(cit):find("Cite") == nil, "citation is not a Cite node")

-- unknown tags survive as literal text rather than disappearing
has(inlines.read("<marquee>hi</marquee>"), "marquee", "unknown tag kept as text")
```

- [ ] **Step 2: Register the suite**

Add `"unit.reader_inlines_test"` to `suites` in `tests/run.lua`.

- [ ] **Step 3: Run the test to verify it fails**

Run: `pandoc lua tests/run.lua`
Expected: FAIL — `module 'notion.reader.inlines' not found`

- [ ] **Step 4: Write the implementation**

Create `notion/reader/inlines.lua`:

```lua
local schema = require "notion.schema"
local attr   = require "notion.attr"

local M = {}

-- Pinned: full `markdown` fabricates Subscript and Cite from text NFM treats
-- literally. Without native_spans every NFM tag arrives as a RawInline pair,
-- so one folding routine covers the whole vocabulary.
M.EXTENSIONS = "markdown_strict+strikeout+tex_math_dollars+backtick_code_blocks"
            .. "+pipe_tables+task_lists+emoji+raw_html+all_symbols_escapable"

local function raw_tag(il)
  if il.t ~= "RawInline" or il.format ~= "html" then return nil end
  local text = il.text
  local closing = text:match("^</([%w_%-]+)>%s*$")
  if closing then return closing, "close", {}, {} end
  local tag = text:match("^<([%w_%-]+)[%s/>]")
  if not tag then return nil end
  local body = text:match("^<[%w_%-]+%s*(.-)%s*/?>") or ""
  local a, order = attr.parse(body)
  if text:match("/>%s*$") then return tag, "void", a, order end
  return tag, "open", a, order
end

-- Build the Span/Underline for one folded tag.
-- Attributes go through attr.ordered so that pandoc.Attr receives an ordered
-- array rather than a map, whose iteration order varies between runs.
local function build(tag, attrs, order, content)
  if tag == "br" then return pandoc.LineBreak() end
  if tag == "span" then
    if attrs.underline == "true" then return pandoc.Underline(content) end
    return pandoc.Span(content, pandoc.Attr("", {}, attr.ordered(attrs, order)))
  end
  local def = schema.MENTION_TAGS[tag]
  if def then
    return pandoc.Span(content, pandoc.Attr("", { "mention", def.class },
                                            attr.ordered(attrs, order)))
  end
  return nil
end

function M.fold(ils)
  local out, i = pandoc.Inlines({}), 1
  while i <= #ils do
    local il = ils[i]
    local tag, kind, attrs, order = raw_tag(il)
    if tag == "br" then
      out:insert(pandoc.LineBreak())
      i = i + 1
    elseif tag and kind == "void" then
      local node = build(tag, attrs, order, pandoc.Inlines({}))
      out:insert(node or pandoc.Str(il.text))
      i = i + 1
    elseif tag and kind == "open" then
      -- collect until the matching close
      local inner, j, depth = pandoc.Inlines({}), i + 1, 1
      while j <= #ils do
        local tg, kd = raw_tag(ils[j])
        if tg == tag and kd == "open" then depth = depth + 1
        elseif tg == tag and kd == "close" then
          depth = depth - 1
          if depth == 0 then break end
        end
        inner:insert(ils[j])
        j = j + 1
      end
      local node = j <= #ils and build(tag, attrs, order, M.fold(inner)) or nil
      if node then
        out:insert(node)
        i = j + 1
      else
        out:insert(pandoc.Str(il.text))     -- unbalanced or unknown: literal
        i = i + 1
      end
    else
      out:insert(il)
      i = i + 1
    end
  end
  return out
end

-- [^URL] survives the pinned reader as literal text; fold it into a citation.
local function fold_citations(ils)
  local out = pandoc.Inlines({})
  for _, il in ipairs(ils) do
    local url = il.t == "Str" and il.text:match("^%[%^(.+)%]$") or nil
    if url then
      out:insert(pandoc.Span(pandoc.Inlines({}),
                             pandoc.Attr("", { "citation" }, { url = url })))
    else
      out:insert(il)
    end
  end
  return out
end

function M.read(text)
  local doc = pandoc.read(text, M.EXTENSIONS)
  local ils = pandoc.utils.blocks_to_inlines(doc.blocks)
  return fold_citations(M.fold(ils))
end

return M
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `pandoc lua tests/run.lua`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add notion/reader/inlines.lua tests/unit/reader_inlines_test.lua tests/run.lua
git commit -m "feat: fold NFM inline tags into the AST convention"
```

---

### Task 7: `reader/blocks.lua` and the reader entry point

First end-to-end milestone: `pandoc -f notion-markdown-reader.lua` produces a real AST. The entry point is pure wiring, so it ships with the module that makes it testable.

**Files:**
- Create: `notion/reader/blocks.lua`
- Create: `notion-markdown-reader.lua`
- Modify: `tests/run.lua`
- Test: `tests/unit/reader_blocks_test.lua`

**Interfaces:**
- Consumes: `notion.reader.tree` (`parse`), `notion.reader.inlines` (`read`), `notion.schema`, `notion.attr`.
- Produces:
  - `notion/reader/blocks.lua` returning `convert(nodes) -> Blocks`
  - `notion-markdown-reader.lua` defining the global `Reader(input, opts) -> Pandoc`

- [ ] **Step 1: Write the failing test**

Create `tests/unit/reader_blocks_test.lua`:

```lua
local t = require "support.assert"
local tree   = require "notion.reader.tree"
local blocks = require "notion.reader.blocks"

local function native(nfm)
  return pandoc.write(pandoc.Pandoc(blocks.convert(tree.parse(nfm))), "native")
end
local function has(nfm, needle, msg)
  t.truthy(native(nfm):find(needle, 1, true) ~= nil, msg)
end

-- paragraphs and the attribute-gap rule
has("Hello", "Para", "plain text becomes Para")
t.truthy(native("Hello"):find("Div") == nil, "unattributed Para is NOT wrapped")
has('Hello {color="blue"}', "Div", "attributed Para IS wrapped")
has('Hello {color="blue"}', '"color" , "blue"', "wrapper carries the color")

-- headings use native Attr, no wrapper
has('# H {color="blue"}', "Header 1", "heading level")
t.truthy(native('# H {color="blue"}'):find("Div") == nil, "heading needs no wrapper")
has('# H {toggle="true"}', '"toggle" , "true"', "toggle attr rides on the Header")

-- h5/h6 collapse to h4
has("##### Five", "Header 4", "h5 collapses to h4")
has("###### Six", "Header 4", "h6 collapses to h4")

-- lists
has("- a\n- b", "BulletList", "bullets group into one list")
t.eq(select(2, native("- a\n- b"):gsub("BulletList", "")), 1, "exactly one BulletList")
has("1. a\n2. b", "OrderedList", "ordered list")
has("- [ ] todo", "\\9744", "unchecked box uses U+2610")
has("- [x] done", "\\9746", "checked box uses U+2612")

-- quote, divider, code, equation
has("> quoted", "BlockQuote", "quote")
has("---", "HorizontalRule", "divider")
has("```lua\nx = 1\n```", "CodeBlock", "code block")
has("```lua\nx = 1\n```", '"lua"', "code language becomes a class")
has("$$a=b$$", "Math DisplayMath", "display equation")

-- containers
has('<callout icon="X" color="blue_bg">\n\tHi\n</callout>', '"callout"', "callout class")
has('<callout icon="X" color="blue_bg">\n\tHi\n</callout>', '"icon" , "X"', "callout icon")
has("<columns>\n<column>\nL\n</column>\n</columns>", '"columns"', "columns class")
has("<columns>\n<column>\nL\n</column>\n</columns>", '"column"', "column class")

-- the two tags real pages contain but the enhanced-markdown spec omits
has('<unknown url="u" alt="bookmark"/>', '"unknown"', "unknown block")
has('<unknown url="u" alt="bookmark"/>', '"alt" , "bookmark"', "unknown alt attribute")

-- toggle vs toggle-heading stay distinct
has("<details>\n<summary>T</summary>\nBody\n</details>", '"toggle"', "details is toggle")
has('# H {toggle="true"}\n\tChild', '"toggle-heading"', "toggle heading with children")

-- single-newline block separation
t.eq(select(2, native("one\ntwo"):gsub("Para", "")), 2,
     "two adjacent lines are two Paras, not one")
```

- [ ] **Step 2: Register the suite**

Add `"unit.reader_blocks_test"` to `suites` in `tests/run.lua`.

- [ ] **Step 3: Run the test to verify it fails**

Run: `pandoc lua tests/run.lua`
Expected: FAIL — `module 'notion.reader.blocks' not found`

- [ ] **Step 4: Write the implementation**

Create `notion/reader/blocks.lua`:

```lua
local schema  = require "notion.schema"
local inlines = require "notion.reader.inlines"
local attr    = require "notion.attr"

local M = {}

-- ALWAYS build Attr through attr.ordered. Handing pandoc.Attr a plain Lua map
-- produces a different attribute order on every run, which makes the
-- byte-exact round-trip suite flaky instead of deterministically failing.
local function attr_of(node, classes)
  return pandoc.Attr("", classes or {}, attr.ordered(node.attrs, node.attr_order))
end

-- Wrap in an attribute-only Div ONLY when the node carries attributes and the
-- pandoc node has no Attr slot of its own.
local function wrap(block, node)
  if next(node.attrs) == nil then return block end
  return pandoc.Div({ block }, attr_of(node))
end

local convert   -- forward declaration; defined below

local function children_of(node)
  return convert(node.children)
end

-- Recognise list-item text and return marker kind plus the remaining content.
local function list_item(text)
  local todo, rest = text:match("^%- %[([ xX])%]%s(.*)$")
  if todo then
    local box = (todo == " ") and "\9744" or "\9746"
    return "bullet", box .. " " .. rest
  end
  local bullet = text:match("^%-%s(.*)$")
  if bullet then return "bullet", bullet end
  local ordered = text:match("^%d+%.%s(.*)$")
  if ordered then return "ordered", ordered end
  return nil
end

local function block_for(node)
  local kind = node.kind

  if kind == "code" then
    local classes = node.info ~= "" and { node.info } or {}
    return pandoc.CodeBlock(node.text, attr_of(node, classes))
  end

  if kind == "tag_open" or kind == "self_closing" or kind == "tag_inline" then
    local tag = node.tag
    local def = schema.BLOCK_TAGS[tag]
    if def then
      local kids = children_of(node)
      if kind == "tag_inline" then
        local label = node.text:match("^<[%w_%-]+.->(.*)</[%w_%-]+>%s*$") or ""
        kids = pandoc.Blocks({ pandoc.Plain(inlines.read(label)) })
      end
      return pandoc.Div(kids, attr_of(node, { def.class }))
    end
    local media = schema.MEDIA_TAGS[tag]
    if media then
      local label = node.text:match("^<[%w_%-]+.->(.*)</[%w_%-]+>%s*$") or ""
      local caption = inlines.read(label)
      local src = node.attrs.src or ""
      local body = pandoc.Blocks({
        pandoc.Plain({ pandoc.Link(caption, src) }) })
      -- src moves onto the inner Link, so drop it from the Figure's own attrs
      -- while keeping the source order of everything else.
      local a, order = {}, {}
      for _, k in ipairs(node.attr_order) do
        if k ~= "src" then a[k] = node.attrs[k]; order[#order + 1] = k end
      end
      return pandoc.Figure(body, pandoc.Caption(nil, { pandoc.Plain(caption) }),
                           pandoc.Attr("", { media.class }, attr.ordered(a, order)))
    end
  end

  local text = node.text

  if text == "---" then return pandoc.HorizontalRule() end

  local hashes, htext = text:match("^(#+)%s(.*)$")
  if hashes and #hashes <= 6 then
    local level = math.min(#hashes, 4)
    local header = pandoc.Header(level, inlines.read(htext), attr_of(node))
    if #node.children > 0 and node.attrs.toggle == "true" then
      local kids = pandoc.Blocks({ header })
      for _, b in ipairs(children_of(node)) do kids:insert(b) end
      return pandoc.Div(kids, pandoc.Attr("", { "toggle-heading" }, {}))
    end
    return header
  end

  local eq = text:match("^%$%$(.*)%$%$$")
  if eq then return wrap(pandoc.Para({ pandoc.Math("DisplayMath", eq) }), node) end

  local quote = text:match("^>%s?(.*)$")
  if quote then
    local body = pandoc.Blocks({ pandoc.Para(inlines.read(quote)) })
    for _, b in ipairs(children_of(node)) do body:insert(b) end
    return wrap(pandoc.BlockQuote(body), node)
  end

  -- ordinary paragraph, possibly with children
  local para = pandoc.Para(inlines.read(text))
  if #node.children > 0 then
    local kids = pandoc.Blocks({ para })
    for _, b in ipairs(children_of(node)) do kids:insert(b) end
    return pandoc.Div(kids, attr_of(node))
  end
  return wrap(para, node)
end

-- Build a list item's blocks: its own content plus any nested children.
local function item_blocks(node, content)
  local first = pandoc.Plain(inlines.read(content))
  local body  = pandoc.Blocks({ next(node.attrs) == nil and first
                                or pandoc.Div({ first }, attr_of(node)) })
  for _, b in ipairs(children_of(node)) do body:insert(b) end
  return body
end

convert = function(nodes)
  local out, i = pandoc.Blocks({}), 1
  while i <= #nodes do
    local node = nodes[i]
    local kind, content = nil, nil
    if node.kind == "text" then kind, content = list_item(node.text) end

    if kind then
      -- gather the run of same-kind siblings into one list
      local items, j = {}, i
      while j <= #nodes do
        local nk, nc = nil, nil
        if nodes[j].kind == "text" then nk, nc = list_item(nodes[j].text) end
        if nk ~= kind then break end
        items[#items + 1] = item_blocks(nodes[j], nc)
        j = j + 1
      end
      out:insert(kind == "bullet" and pandoc.BulletList(items)
                                   or pandoc.OrderedList(items))
      i = j
    else
      out:insert(block_for(node))
      i = i + 1
    end
  end
  return out
end

M.convert = convert
return M
```

Create `notion-markdown-reader.lua`:

```lua
-- Put this script's own directory on package.path. Pandoc does NOT do this:
-- package.path contains only the system paths and ./?.lua.
local dir = PANDOC_SCRIPT_FILE:match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/?.lua;" .. dir .. "/?/init.lua;" .. package.path

local tree   = require "notion.reader.tree"
local blocks = require "notion.reader.blocks"

function Reader(input, opts)
  return pandoc.Pandoc(blocks.convert(tree.parse(tostring(input))))
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `pandoc lua tests/run.lua`
Expected: PASS

- [ ] **Step 6: Verify the reader works end-to-end from the command line**

```bash
printf 'Hi {color="blue"}\n<callout icon="X">\n\tIn **callout**\n</callout>\n' \
  | pandoc -f ./notion-markdown-reader.lua -t native
```
Expected: a `Div` with `color="blue"` around a `Para`, and a `Div` with class `callout`.

- [ ] **Step 7: Commit**

```bash
git add notion/reader/blocks.lua notion-markdown-reader.lua \
        tests/unit/reader_blocks_test.lua tests/run.lua
git commit -m "feat: add NFM reader entry point and block conversion"
```

---

### Task 8: `writer/inlines.lua`

Renders pandoc inlines back to NFM text. Escaping lives here, and must be suppressed inside `Code`.

**Files:**
- Create: `notion/writer/inlines.lua`
- Modify: `tests/run.lua`
- Test: `tests/unit/writer_inlines_test.lua`

**Interfaces:**
- Consumes: `notion.escape`, `notion.attr`, `notion.schema`.
- Produces: `notion/writer/inlines.lua` returning `render(inlines) -> string`.

- [ ] **Step 1: Write the failing test**

Create `tests/unit/writer_inlines_test.lua`:

```lua
local t = require "support.assert"
local w = require "notion.writer.inlines"

local function ils(md)
  local d = pandoc.read(md, "markdown")
  return pandoc.utils.blocks_to_inlines(d.blocks)
end
local function out(md) return w.render(ils(md)) end

t.eq(out("**b**"), "**b**", "bold")
t.eq(out("*i*"), "*i*", "italic")
t.eq(out("~~s~~"), "~~s~~", "strikeout")
t.eq(out("`c`"), "`c`", "inline code")
t.eq(out("[t](http://x)"), "[t](http://x)", "link")
t.eq(out("$e=mc$"), "$e=mc$", "inline math")

-- special characters are escaped outside code
t.eq(w.render({ pandoc.Str("a{b}c") }), "a\\{b\\}c", "braces escaped")
t.eq(w.render({ pandoc.Str("100% ^ 2") }), "100% \\^ 2", "caret escaped")

-- but NOT inside code
t.eq(w.render({ pandoc.Code("a{b}c") }), "`a{b}c`", "code content is literal")

-- convention round-trips
t.eq(w.render({ pandoc.Underline({ pandoc.Str("u") }) }),
     '<span underline="true">u</span>', "underline")
t.eq(w.render({ pandoc.Span({ pandoc.Str("c") }, pandoc.Attr("", {}, { color = "red" })) }),
     '<span color="red">c</span>', "inline color")
t.eq(w.render({ pandoc.LineBreak() }), "<br>", "line break")
t.eq(w.render({ pandoc.Span({ pandoc.Str("Ada") },
        pandoc.Attr("", { "mention", "mention-user" }, { url = "u://1" })) }),
     '<mention-user url="u://1">Ada</mention-user>', "mention")
t.eq(w.render({ pandoc.Span({}, pandoc.Attr("", { "citation" }, { url = "http://x" })) }),
     "[^http://x]", "citation")
t.eq(w.render({ pandoc.Span({ pandoc.Str("\128516") },
        pandoc.Attr("", { "emoji" }, { ["data-emoji"] = "smile" })) }),
     ":smile:", "custom emoji")

-- degradation: NFM-native fallbacks, never raw HTML
t.eq(w.render({ pandoc.SmallCaps({ pandoc.Str("abc") }) }), "ABC", "smallcaps uppercases")
t.eq(w.render({ pandoc.Subscript({ pandoc.Str("2") }) }), "\226\130\130",
     "subscript uses Unicode")
t.eq(w.render({ pandoc.Superscript({ pandoc.Str("2") }) }), "\194\178",
     "superscript uses Unicode")
```

- [ ] **Step 2: Register the suite**

Add `"unit.writer_inlines_test"` to `suites` in `tests/run.lua`.

- [ ] **Step 3: Run the test to verify it fails**

Run: `pandoc lua tests/run.lua`
Expected: FAIL — `module 'notion.writer.inlines' not found`

- [ ] **Step 4: Write the implementation**

Create `notion/writer/inlines.lua`:

```lua
local escape = require "notion.escape"
local attr   = require "notion.attr"
local schema = require "notion.schema"

local M = {}

-- Unicode sub/superscript digits, the `plain` writer's strategy. NFM's HTML
-- vocabulary is closed, so <sub>/<sup> would reach Notion as literal text.
local SUB = { ["0"]="\226\130\128", ["1"]="\226\130\129", ["2"]="\226\130\130",
              ["3"]="\226\130\131", ["4"]="\226\130\132", ["5"]="\226\130\133",
              ["6"]="\226\130\134", ["7"]="\226\130\135", ["8"]="\226\130\136",
              ["9"]="\226\130\137" }
local SUP = { ["0"]="\226\129\176", ["1"]="\194\185",     ["2"]="\194\178",
              ["3"]="\194\179",     ["4"]="\226\129\180", ["5"]="\226\129\181",
              ["6"]="\226\129\182", ["7"]="\226\129\183", ["8"]="\226\129\184",
              ["9"]="\226\129\185" }

local render     -- forward declaration

local function map_digits(text, table_)
  local out, ok = {}, true
  for c in text:gmatch(".") do
    if table_[c] then out[#out + 1] = table_[c] else ok = false; out[#out + 1] = c end
  end
  return table.concat(out), ok
end

local function span(el)
  local classes = {}
  for _, c in ipairs(el.classes) do classes[c] = true end

  if classes.citation then
    return "[^" .. (el.attributes.url or "") .. "]"
  end
  if classes.emoji then
    return ":" .. (el.attributes["data-emoji"] or "") .. ":"
  end
  if classes.mention then
    for _, c in ipairs(el.classes) do
      local def = schema.MENTION_TAGS[c]
      if def then
        -- ipairs order, never pairs: source attribute order must survive.
        local a, order = attr.from_attr(el.attributes)
        if #order == 0 then order = def.attrs end
        local body = attr.render(a, order):gsub("^ {", ""):gsub("}$", "")
        local inner = render(el.content)
        if inner == "" then return "<" .. c .. " " .. body .. "/>" end
        return "<" .. c .. " " .. body .. ">" .. inner .. "</" .. c .. ">"
      end
    end
  end
  -- plain attribute span, e.g. inline color
  local a, order = attr.from_attr(el.attributes)
  local body = attr.render(a, order):gsub("^ {", ""):gsub("}$", "")
  if body == "" then return render(el.content) end
  return "<span " .. body .. ">" .. render(el.content) .. "</span>"
end

local handlers = {
  Str        = function(el) return escape.escape(el.text) end,
  Space      = function() return " " end,
  SoftBreak  = function() return " " end,
  LineBreak  = function() return "<br>" end,
  Strong     = function(el) return "**" .. render(el.content) .. "**" end,
  Emph       = function(el) return "*" .. render(el.content) .. "*" end,
  Strikeout  = function(el) return "~~" .. render(el.content) .. "~~" end,
  Underline  = function(el) return '<span underline="true">' .. render(el.content) .. "</span>" end,
  Code       = function(el) return "`" .. el.text .. "`" end,   -- literal, never escaped
  Math       = function(el)
                 if el.mathtype == "DisplayMath" then return "$$" .. el.text .. "$$" end
                 return "$" .. el.text .. "$"
               end,
  Link       = function(el) return "[" .. render(el.content) .. "](" .. el.target .. ")" end,
  Image      = function(el) return "![" .. render(el.caption) .. "](" .. el.src .. ")" end,
  Span       = span,
  Quoted     = function(el)
                 local q = el.quotetype == "SingleQuote" and "'" or '"'
                 return q .. render(el.content) .. q
               end,
  SmallCaps  = function(el) return render(el.content):upper() end,
  Subscript  = function(el) return (map_digits(render(el.content), SUB)) end,
  Superscript= function(el) return (map_digits(render(el.content), SUP)) end,
  Cite       = function(el) return render(el.content) end,
  Note       = function() return "" end,   -- handled by the block writer
  RawInline  = function(el)
                 if el.format == "html" then return el.text end
                 pandoc.log.info("Not rendering RawInline (Format \"" .. el.format .. "\")")
                 return ""
               end,
}

render = function(ils)
  local out = {}
  for _, il in ipairs(ils or {}) do
    local h = handlers[il.t]
    if h then out[#out + 1] = h(il)
    else out[#out + 1] = pandoc.utils.stringify(il) end
  end
  return table.concat(out)
end

M.render = render
M.handlers = handlers
return M
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `pandoc lua tests/run.lua`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add notion/writer/inlines.lua tests/unit/writer_inlines_test.lua tests/run.lua
git commit -m "feat: render pandoc inlines as NFM"
```

---

### Task 9: `writer/blocks.lua` and the writer entry point

Second end-to-end milestone. After this task, round-tripping is possible.

**Files:**
- Create: `notion/writer/blocks.lua`
- Create: `notion-markdown-writer.lua`
- Modify: `tests/run.lua`
- Test: `tests/unit/writer_blocks_test.lua`

**Interfaces:**
- Consumes: `notion.writer.inlines` (`render`), `notion.schema`, `notion.attr`.
- Produces:
  - `notion/writer/blocks.lua` returning `render(blocks, depth) -> string`
  - `notion-markdown-writer.lua` defining the global `Writer(doc, opts) -> string`

- [ ] **Step 1: Write the failing test**

Create `tests/unit/writer_blocks_test.lua`:

```lua
local t = require "support.assert"
local w = require "notion.writer.blocks"

local function out(blocks) return w.render(pandoc.Blocks(blocks), 0) end

t.eq(out({ pandoc.Para({ pandoc.Str("Hi") }) }), "Hi", "paragraph")

-- blocks are separated by a SINGLE newline, not a blank line
t.eq(out({ pandoc.Para({ pandoc.Str("a") }), pandoc.Para({ pandoc.Str("b") }) }),
     "a\nb", "single newline between blocks")

-- attribute-only Div unwraps back onto its child's attribute suffix
t.eq(out({ pandoc.Div({ pandoc.Para({ pandoc.Str("Hi") }) },
                      pandoc.Attr("", {}, { color = "blue" })) }),
     'Hi {color="blue"}', "attribute Div becomes a suffix")

-- headings
t.eq(out({ pandoc.Header(1, { pandoc.Str("H") }) }), "# H", "h1")
t.eq(out({ pandoc.Header(4, { pandoc.Str("H") }) }), "#### H", "h4")
t.eq(out({ pandoc.Header(2, { pandoc.Str("H") }, pandoc.Attr("", {}, { color = "blue" })) }),
     '## H {color="blue"}', "heading with color")

-- lists and to-dos
t.eq(out({ pandoc.BulletList({ { pandoc.Plain({ pandoc.Str("a") }) },
                               { pandoc.Plain({ pandoc.Str("b") }) } }) }),
     "- a\n- b", "bullet list")
t.eq(out({ pandoc.BulletList({ { pandoc.Plain({ pandoc.Str("\9744 t") }) } }) }),
     "- [ ] t", "unchecked to-do")
t.eq(out({ pandoc.BulletList({ { pandoc.Plain({ pandoc.Str("\9746 t") }) } }) }),
     "- [x] t", "checked to-do")
t.eq(out({ pandoc.OrderedList({ { pandoc.Plain({ pandoc.Str("a") }) } }) }),
     "1. a", "ordered list")

-- children indent with a TAB, never spaces
local nested = out({ pandoc.BulletList({
  { pandoc.Plain({ pandoc.Str("parent") }), pandoc.Para({ pandoc.Str("child") }) } }) })
t.eq(nested, "- parent\n\tchild", "child is tab-indented")
t.truthy(nested:find("    ") == nil, "no space indentation anywhere")

-- code is literal and fenced
t.eq(out({ pandoc.CodeBlock("x = {1}", pandoc.Attr("", { "lua" }, {})) }),
     "```lua\nx = {1}\n```", "code block content is not escaped")

-- structures
t.eq(out({ pandoc.HorizontalRule() }), "---", "divider")
t.eq(out({ pandoc.Para({ pandoc.Math("DisplayMath", "a=b") }) }), "$$a=b$$", "equation")
t.eq(out({ pandoc.Div({ pandoc.Para({ pandoc.Str("Hi") }) },
                      pandoc.Attr("", { "callout" }, { icon = "X", color = "b" })) }),
     '<callout icon="X" color="b">\n\tHi\n</callout>', "callout with tab-indented child")
t.eq(out({ pandoc.Div({}, pandoc.Attr("", { "empty-block" }, {})) }),
     "<empty-block/>", "empty block")
t.eq(out({ pandoc.Div({}, pandoc.Attr("", { "unknown" }, { url = "u", alt = "bookmark" })) }),
     '<unknown url="u" alt="bookmark"/>', "unknown block")

-- footnotes degrade to an endnote, not raw HTML
local note = out({ pandoc.Para({ pandoc.Str("x"),
  pandoc.Note({ pandoc.Para({ pandoc.Str("body") }) }) }) })
t.truthy(note:find("[1]", 1, true) ~= nil, "footnote leaves a marker")
t.truthy(note:find("body", 1, true) ~= nil, "and the body appears as an endnote")
```

- [ ] **Step 2: Register the suite**

Add `"unit.writer_blocks_test"` to `suites` in `tests/run.lua`.

- [ ] **Step 3: Run the test to verify it fails**

Run: `pandoc lua tests/run.lua`
Expected: FAIL — `module 'notion.writer.blocks' not found`

- [ ] **Step 4: Write the implementation**

Create `notion/writer/blocks.lua`:

```lua
local inl    = require "notion.writer.inlines"
local schema = require "notion.schema"
local attr   = require "notion.attr"

local M = {}

local render      -- forward declaration
local notes = {}  -- collected footnote bodies for the endnote section

local function tabs(n) return string.rep("\t", n) end

-- Read the AttributeList in its PRESERVED order (ipairs, never pairs) so that
-- attributes come back out in the order the source wrote them. Using pairs()
-- here would reorder them non-deterministically and break byte-exact
-- round-trip.
local function attr_suffix(attributes)
  local a, order = attr.from_attr(attributes)
  if #order == 0 then return "" end
  return attr.render(a, order)
end

-- Render a tag block: <tag k="v">\n\t<children>\n</tag>
-- Source order wins; def.attrs only supplies an order for documents that did
-- not come from NFM in the first place.
local function tag_block(tag, def, el, depth)
  local a, order = attr.from_attr(el.attributes)
  if #order == 0 then order = def.attrs end
  local body = attr.render(a, order):gsub("^ {", " "):gsub("}$", "")
  local open = "<" .. tag .. body
  if def.void then return tabs(depth) .. open .. "/>" end
  local kids = render(el.content, depth + 1)
  if kids == "" then return tabs(depth) .. open .. "></" .. tag .. ">" end
  return tabs(depth) .. open .. ">\n" .. kids .. "\n" .. tabs(depth) .. "</" .. tag .. ">"
end

local function div(el, depth)
  local classes = el.classes

  -- attribute-only Div: unwrap, pushing attributes onto the single child
  if #classes == 0 then
    local inner = render(el.content, depth)
    local suffix = attr_suffix(el.attributes)
    if suffix == "" then return inner end
    -- attach to the first line only
    local first, rest = inner:match("^([^\n]*)(.*)$")
    return first .. suffix .. rest
  end

  if classes[1] == "toggle-heading" then
    return render(el.content, depth)
  end

  local tag, kind = schema.class_to_tag(classes[1])
  if tag and kind == "block" then
    return tag_block(tag, schema.BLOCK_TAGS[tag], el, depth)
  end

  -- unknown class: render the children, losing only the wrapper
  return render(el.content, depth)
end

local function list(el, depth, marker)
  local out = {}
  for i, item in ipairs(el.content) do
    local body = render(pandoc.Blocks(item), depth + 1)
    -- first line carries the marker; the rest stays tab-indented
    local first, rest = body:match("^" .. tabs(depth + 1) .. "([^\n]*)(.*)$")
    first = first or body
    local m = type(marker) == "function" and marker(i) or marker
    -- to-do boxes come back from the AST as U+2610 / U+2612 prefixes
    local box, text = first:match("^([\9744\9746])%s(.*)$")
    if box then
      m = m .. (box == "\9744" and "[ ] " or "[x] ")
      first = text
    end
    out[#out + 1] = tabs(depth) .. m .. first .. (rest or "")
  end
  return table.concat(out, "\n")
end

local handlers = {
  Para  = function(el, d) return tabs(d) .. inl.render(el.content) end,
  Plain = function(el, d) return tabs(d) .. inl.render(el.content) end,

  Header = function(el, d)
    return tabs(d) .. string.rep("#", math.min(el.level, 4)) .. " "
           .. inl.render(el.content) .. attr_suffix(el.attr.attributes)
  end,

  BlockQuote = function(el, d)
    local body = render(el.content, 0):gsub("\n", "<br>")
    return tabs(d) .. "> " .. body
  end,

  BulletList  = function(el, d) return list(el, d, "- ") end,
  OrderedList = function(el, d) return list(el, d, function(i) return i .. ". " end) end,

  CodeBlock = function(el, d)
    local lang = el.classes[1] or ""
    local body = {}
    for line in (el.text .. "\n"):gmatch("(.-)\n") do body[#body + 1] = tabs(d) .. line end
    return tabs(d) .. "```" .. lang .. "\n" .. table.concat(body, "\n")
           .. "\n" .. tabs(d) .. "```"
  end,

  HorizontalRule = function(_, d) return tabs(d) .. "---" end,

  Div = div,

  Figure = function(el, d)
    local caption = inl.render(pandoc.utils.blocks_to_inlines(el.caption.long or {}))
    local class = el.classes[1]
    local media = class and schema.MEDIA_TAGS[class]
    if media then
      local a, order = attr.from_attr(el.attributes)
      -- src lives on the inner Link, not on the Figure's attributes; it leads
      -- the attribute list because that is where NFM writes it.
      local src = ""
      pandoc.walk_block(el, { Link = function(l) src = l.target end })
      a.src = src
      table.insert(order, 1, "src")
      local body = attr.render(a, order):gsub("^ {", " "):gsub("}$", "")
      return tabs(d) .. "<" .. class .. body .. ">" .. caption .. "</" .. class .. ">"
    end
    local src = ""
    pandoc.walk_block(el, { Image = function(i) src = i.src end })
    return tabs(d) .. "![" .. caption .. "](" .. src .. ")"
  end,

  Table = function(el, d)
    -- Table cells hold rich text only; block content in a cell is a true drop.
    local rows = {}
    local function emit_rows(section, tag)
      for _, row in ipairs(section) do
        local cells = {}
        for _, cell in ipairs(row.cells) do
          local text = inl.render(pandoc.utils.blocks_to_inlines(cell.contents))
          for _, b in ipairs(cell.contents) do
            if b.t ~= "Plain" and b.t ~= "Para" then
              pandoc.log.info("Not rendering " .. b.t .. " inside table cell")
            end
          end
          cells[#cells + 1] = tabs(d + 2) .. "<" .. tag .. ">" .. text .. "</" .. tag .. ">"
        end
        rows[#rows + 1] = tabs(d + 1) .. "<tr>\n" .. table.concat(cells, "\n")
                          .. "\n" .. tabs(d + 1) .. "</tr>"
      end
    end
    emit_rows(el.head.rows, "td")
    for _, body in ipairs(el.bodies) do emit_rows(body.body, "td") end
    return tabs(d) .. "<table>\n" .. table.concat(rows, "\n") .. "\n" .. tabs(d) .. "</table>"
  end,

  DefinitionList = function(el, d)
    local out = {}
    for _, entry in ipairs(el.content) do
      out[#out + 1] = tabs(d) .. "**" .. inl.render(entry[1]) .. "**"
      for _, def in ipairs(entry[2]) do
        out[#out + 1] = render(pandoc.Blocks(def), d + 1)
      end
    end
    return table.concat(out, "\n")
  end,

  LineBlock = function(el, d)
    local parts = {}
    for _, line in ipairs(el.content) do parts[#parts + 1] = inl.render(line) end
    return tabs(d) .. table.concat(parts, "<br>")
  end,

  RawBlock = function(el, d)
    if el.format == "html" then return tabs(d) .. el.text end
    pandoc.log.info('Not rendering RawBlock (Format "' .. el.format .. '")')
    return ""
  end,
}

render = function(blocks, depth)
  local out = {}
  for _, b in ipairs(blocks or {}) do
    local h = handlers[b.t]
    local text
    if h then text = h(b, depth or 0)
    else text = (depth and tabs(depth) or "") .. pandoc.utils.stringify(b) end
    if text ~= "" then out[#out + 1] = text end
  end
  return table.concat(out, "\n")     -- single newline between blocks
end

-- Footnotes: NFM has none. Leave a [n] marker and append the bodies as
-- endnote blocks at the end of the document.
function M.extract_notes(doc)
  notes = {}
  local n = 0
  local walked = doc:walk({
    Note = function(el)
      n = n + 1
      notes[#notes + 1] = { index = n, blocks = el.content }
      return pandoc.Str("[" .. n .. "]")
    end,
  })
  return walked, notes
end

function M.render_document(doc)
  local walked, collected = M.extract_notes(doc)
  local body = render(walked.blocks, 0)
  if #collected == 0 then return body end
  local parts = { body }
  for _, note in ipairs(collected) do
    parts[#parts + 1] = "[" .. note.index .. "] " .. render(note.blocks, 0)
  end
  return table.concat(parts, "\n")
end

M.render = render
M.handlers = handlers
return M
```

Create `notion-markdown-writer.lua`:

```lua
local dir = PANDOC_SCRIPT_FILE:match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/?.lua;" .. dir .. "/?/init.lua;" .. package.path

local blocks = require "notion.writer.blocks"

function Writer(doc, opts)
  return blocks.render_document(doc)
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `pandoc lua tests/run.lua`
Expected: PASS

- [ ] **Step 6: Verify a round-trip works end-to-end**

```bash
printf 'Hi {color="blue"}\n<callout icon="X">\n\tIn **callout**\n</callout>\n' \
  | pandoc -f ./notion-markdown-reader.lua -t ./notion-markdown-writer.lua
```
Expected: output identical to the input.

- [ ] **Step 7: Commit**

```bash
git add notion/writer/blocks.lua notion-markdown-writer.lua \
        tests/unit/writer_blocks_test.lua tests/run.lua
git commit -m "feat: add NFM writer entry point and block rendering"
```

---

### Task 10: Round-trip corpus and idempotence harness

The strongest test in the suite, and self-checking: no hand-written expected output, so each new fixture costs one file.

**Files:**
- Create: `tests/support/nfm.lua`
- Create: `tests/corpus/blocks/*.nfm` (23 files, listed below)
- Create: `tests/corpus/inlines/*.nfm` (7 files)
- Create: `tests/corpus/nesting/*.nfm` (5 files)
- Create: `tests/corpus/adversarial/*.nfm` (4 files)
- Create: `tests/roundtrip_test.lua`
- Modify: `tests/run.lua`

**Interfaces:**
- Consumes: the reader and writer entry points, via `pandoc.pipe`.
- Produces: `tests/support/nfm.lua` returning
  `{ to_nfm(text) -> string, to_native(text) -> string, read_file(path) -> string, list(dir) -> string[] }`.

- [ ] **Step 1: Write the pandoc-shelling helper**

Create `tests/support/nfm.lua`:

```lua
local M = {}

local ROOT = (arg[0] or ""):match("^(.*)[/\\]tests[/\\]") or "."
M.ROOT = ROOT

local READER = ROOT .. "/notion-markdown-reader.lua"
local WRITER = ROOT .. "/notion-markdown-writer.lua"

function M.to_nfm(text)
  return pandoc.pipe("pandoc", { "-f", READER, "-t", WRITER }, text)
end

function M.to_native(text)
  return pandoc.pipe("pandoc", { "-f", READER, "-t", "native" }, text)
end

function M.read_file(path)
  local fh = assert(io.open(path, "rb"))
  local data = fh:read("a")
  fh:close()
  return data
end

-- List *.nfm under a corpus subdirectory, sorted for deterministic runs.
function M.list(subdir)
  local dir = ROOT .. "/tests/corpus/" .. subdir
  local out = {}
  local pipe = io.popen("ls " .. dir .. "/*.nfm 2>/dev/null")
  if pipe then
    for line in pipe:lines() do out[#out + 1] = line end
    pipe:close()
  end
  table.sort(out)
  return out
end

return M
```

- [ ] **Step 2: Write the failing round-trip test**

Create `tests/roundtrip_test.lua`:

```lua
local t   = require "support.assert"
local nfm = require "support.nfm"

local SUBDIRS = { "blocks", "inlines", "nesting", "adversarial" }

local count = 0
for _, sub in ipairs(SUBDIRS) do
  for _, path in ipairs(nfm.list(sub)) do
    count = count + 1
    local src = nfm.read_file(path):gsub("\n$", "")
    local once = nfm.to_nfm(src):gsub("\n$", "")
    local name = path:match("[^/]+$")

    -- Authored fixtures are written in canonical form, so the first pass must
    -- already be byte-identical.
    t.eq(once, src, "round-trip is byte-identical: " .. name)

    -- And conversion is stable: applying it again changes nothing.
    local twice = nfm.to_nfm(once):gsub("\n$", "")
    t.eq(twice, once, "round-trip is idempotent: " .. name)
  end
end

t.truthy(count >= 39, "corpus has at least 39 fixtures, found " .. count)
```

- [ ] **Step 3: Register the suite**

Add `"roundtrip_test"` to `suites` in `tests/run.lua`.

- [ ] **Step 4: Run to verify it fails**

Run: `pandoc lua tests/run.lua`
Expected: FAIL — `corpus has at least 39 fixtures, found 0`

- [ ] **Step 5: Write the corpus fixtures**

Create each file with exactly the content shown. Use literal tabs for indentation.

`tests/corpus/blocks/paragraph.nfm`:
```
Plain paragraph text.
Colored paragraph. {color="blue"}
```

`tests/corpus/blocks/headings.nfm`:
```
# Heading one
## Heading two
### Heading three
#### Heading four
# Colored heading {color="blue"}
```

`tests/corpus/blocks/toggle-heading.nfm`:
```
# Toggle heading {toggle="true"}
	Child of the toggle heading.
```

`tests/corpus/blocks/details.nfm`:
```
<details color="blue">
	<summary>
		Toggle title
	</summary>
	Body of the toggle.
</details>
```

`tests/corpus/blocks/lists-bullet.nfm`:
```
- First bullet
- Second bullet
- Colored bullet {color="red"}
```

`tests/corpus/blocks/lists-ordered.nfm`:
```
1. First item
2. Second item
```

`tests/corpus/blocks/todo.nfm`:
```
- [ ] Unchecked item
- [x] Checked item
```

`tests/corpus/blocks/quote.nfm`:
```
> A single line quote.
> Line one<br>Line two<br>Line three
> Another separate quote block.
```

`tests/corpus/blocks/callout.nfm`:
```
<callout icon="🎯" color="blue_bg">
	Ship the MVP by **Friday**.
</callout>
```

`tests/corpus/blocks/code.nfm`:
```
```python
def greet(name):
    return f"Hello, {name}!"
```
```

`tests/corpus/blocks/code-mermaid.nfm`:
```
```mermaid
graph TD; A-->B;
```
```

`tests/corpus/blocks/equation.nfm`:
```
$$E = mc^2$$
```

`tests/corpus/blocks/table.nfm`:
```
<table>
	<tr>
		<td>Status</td>
		<td>Owner</td>
	</tr>
	<tr>
		<td>In progress</td>
		<td>Ada</td>
	</tr>
</table>
```

`tests/corpus/blocks/divider.nfm`:
```
---
```

`tests/corpus/blocks/empty-block.nfm`:
```
Before the gap.
<empty-block/>
After the gap.
```

`tests/corpus/blocks/columns.nfm`:
```
<columns>
	<column>
		Left column text.
	</column>
	<column>
		Right column text.
	</column>
</columns>
```

`tests/corpus/blocks/media-image.nfm`:
```
![A caption](https://example.com/i.png)
```

`tests/corpus/blocks/media-av.nfm`:
```
<audio src="https://example.com/a.mp3">Audio caption</audio>
<video src="https://example.com/v.mp4">Video caption</video>
<file src="https://example.com/f.zip">File caption</file>
<pdf src="https://example.com/d.pdf">PDF caption</pdf>
```

`tests/corpus/blocks/page-database.nfm`:
```
<page url="https://notion.so/p">Child page title</page>
<database url="https://notion.so/d" inline="true">Database name</database>
```

`tests/corpus/blocks/toc.nfm`:
```
<table_of_contents/>
```

`tests/corpus/blocks/synced-block.nfm`:
```
<synced_block url="https://notion.so/s">
	Synced content.
</synced_block>
```

`tests/corpus/blocks/unknown-block.nfm`:
```
<unknown url="https://notion.com/abc123#def456" alt="bookmark"/>
```

`tests/corpus/blocks/meeting-notes.nfm`:
```
<meeting-notes>
	Transcript body.
</meeting-notes>
```

`tests/corpus/inlines/emphasis.nfm`:
```
**Bold** and *italic* and ~~struck~~ and `code`.
```

`tests/corpus/inlines/underline-color.nfm`:
```
<span underline="true">Underlined</span> and <span color="red">red</span>.
```

`tests/corpus/inlines/links-math.nfm`:
```
A [link](https://example.com) and inline $e=mc^2$ math.
```

`tests/corpus/inlines/mentions.nfm`:
```
<mention-user url="https://notion.so/u">Ada</mention-user>
<mention-page url="https://notion.so/p">Page</mention-page>
<mention-database url="https://notion.so/d">Database</mention-database>
<mention-data-source url="https://notion.so/ds">Source</mention-data-source>
<mention-agent url="https://notion.so/a">Agent</mention-agent>
<mention-date start="2026-01-01"/>
```

`tests/corpus/inlines/emoji.nfm`:
```
A custom :sparkles: emoji.
```

`tests/corpus/inlines/citation.nfm`:
```
A claim with a source. [^https://example.com/source]
```

`tests/corpus/inlines/linebreak.nfm`:
```
First line<br>Second line
```

`tests/corpus/nesting/deep-tabs.nfm`:
```
- Level one
	Level two
		Level three
			Level four
```

`tests/corpus/nesting/callout-in-column.nfm`:
```
<columns>
	<column>
		<callout icon="X" color="green_bg">
			Nested callout.
		</callout>
	</column>
</columns>
```

`tests/corpus/nesting/list-with-block-children.nfm`:
```
- Parent bullet
	A child paragraph.
	<callout icon="!">
		A callout inside a list item.
	</callout>
```

`tests/corpus/nesting/single-newline-blocks.nfm`:
```
# Meeting Notes
Discussed roadmap priorities.
## Action items
- [ ] Draft proposal
- [ ] Schedule follow-up
```

`tests/corpus/nesting/fence-containing-nfm.nfm`:
```
```text
<callout icon="X">
	Not a real callout {color="blue"}
</callout>
```
```

`tests/corpus/adversarial/escapes.nfm`:
```
Escaped specials: \\ \* \~ \` \$ \[ \] \< \> \{ \} \| \^
```

`tests/corpus/adversarial/literal-attrs.nfm`:
```
See the {color} field in the docs.
This mentions {not an attr} in passing.
```

`tests/corpus/adversarial/unbalanced-tags.nfm`:
```
A stray closing tag follows.
</callout>
```

`tests/corpus/adversarial/crlf-trailing-ws.nfm`:
```
A line with no trailing whitespace.
Another plain line.
```

- [ ] **Step 6: Run the test and fix fixtures or code until green**

Run: `pandoc lua tests/run.lua`

Expected: PASS. If a fixture fails byte-identity, decide deliberately which side is wrong — the fixture may not be in canonical form (fix the fixture), or the reader and writer genuinely disagree (fix the code). Do not "fix" a failure by relaxing the assertion.

- [ ] **Step 7: Commit**

```bash
git add tests/support/nfm.lua tests/roundtrip_test.lua tests/corpus tests/run.lua
git commit -m "test: add NFM round-trip corpus and idempotence harness"
```

---

### Task 11: Degradation tests

Pins the lossy-input policy: deterministic NFM-native fallbacks, silent by default, `[INFO]` only on true drops. Silence is asserted as strictly as output, because the spec makes silence a requirement rather than an absence.

**Files:**
- Create: `tests/degrade/*.md` (6 files)
- Create: `tests/degrade_test.lua`
- Modify: `tests/support/nfm.lua` (add `from_markdown_verbose`)
- Modify: `tests/run.lua`

**Interfaces:**
- Consumes: the writer entry point.
- Produces: `nfm.from_markdown(text) -> string` and
  `nfm.from_markdown_verbose(text) -> stdout, stderr`.

- [ ] **Step 1: Extend the helper to capture stderr**

Append to `tests/support/nfm.lua`, before `return M`:

```lua
function M.from_markdown(text)
  return pandoc.pipe("pandoc", { "-f", "markdown", "-t", WRITER }, text)
end

-- Run the writer with --verbose and capture stdout and stderr separately, so
-- tests can assert on log level. pandoc.pipe cannot split streams, so shell out.
function M.from_markdown_verbose(text)
  local tmp_in  = os.tmpname()
  local tmp_err = os.tmpname()
  local fh = assert(io.open(tmp_in, "wb")); fh:write(text); fh:close()
  local cmd = string.format("pandoc --verbose -f markdown -t %q %q 2>%q",
                            WRITER, tmp_in, tmp_err)
  local out_pipe = assert(io.popen(cmd, "r"))
  local out = out_pipe:read("a"); out_pipe:close()
  local err_fh = assert(io.open(tmp_err, "rb"))
  local err = err_fh:read("a"); err_fh:close()
  os.remove(tmp_in); os.remove(tmp_err)
  return out, err
end
```

- [ ] **Step 2: Write the failing test**

Create `tests/degrade_test.lua`:

```lua
local t   = require "support.assert"
local nfm = require "support.nfm"

local function contains(hay, needle, msg) t.truthy(hay:find(needle, 1, true) ~= nil, msg) end
local function lacks(hay, needle, msg)    t.truthy(hay:find(needle, 1, true) == nil, msg) end

-- Footnote: [n] marker plus an endnote, no raw HTML.
local fn = nfm.from_markdown("Text with a note.[^1]\n\n[^1]: The note body.\n")
contains(fn, "[1]", "footnote leaves a numeric marker")
contains(fn, "The note body.", "note body appears as an endnote")
lacks(fn, "<sup", "no raw HTML fallback")

-- Definition list: bold term plus indented child.
local dl = nfm.from_markdown("Term\n:   Definition of term.\n")
contains(dl, "**Term**", "term becomes bold")
contains(dl, "\tDefinition of term.", "definition becomes a tab-indented child")

-- Line block: <br>, which is genuinely NFM-native.
local lb = nfm.from_markdown("| A line\n| Second line\n")
contains(lb, "A line<br>Second line", "line block uses <br>")

-- Small caps uppercase; no smallcaps span.
local sc = nfm.from_markdown("[abc]{.smallcaps}\n")
contains(sc, "ABC", "small caps uppercased")
lacks(sc, "smallcaps", "no class=\"smallcaps\" span")

-- Sub/superscript use Unicode, never <sub>/<sup>.
local ss = nfm.from_markdown("H~2~O and x^2^\n")
lacks(ss, "<sub", "no <sub> tag")
lacks(ss, "<sup", "no <sup> tag")
contains(ss, "\226\130\130", "subscript two is U+2082")
contains(ss, "\194\178", "superscript two is U+00B2")

-- Degradation is SILENT at default verbosity.
local _, err_default = nfm.from_markdown_verbose("Text with a note.[^1]\n\n[^1]: Body.\n")
-- (verbose run used only to confirm the INFO channel; assert quiet separately)
local quiet = io.popen(
  string.format("printf 'Term\\n:   Def.\\n' | pandoc -f markdown -t %q 2>&1 >/dev/null",
                nfm.ROOT .. "/notion-markdown-writer.lua"), "r")
local quiet_err = quiet:read("a"); quiet:close()
t.eq(quiet_err, "", "approximation logs nothing at default verbosity")

-- A TRUE DROP logs [INFO]: block content inside a table cell.
local nested_cell = table.concat({
  "+---------+", "| - a     |", "|   - b   |", "+---------+", "" }, "\n")
local _, err_drop = nfm.from_markdown_verbose(nested_cell)
contains(err_drop, "INFO", "true drop is logged at INFO")
contains(err_drop, "table cell", "and names the location")
```

- [ ] **Step 3: Create the degrade inputs**

These document the cases and are useful for manual inspection.

`tests/degrade/footnote.md`:
```
Text with a note.[^1]

[^1]: The note body.
```

`tests/degrade/deflist.md`:
```
Term
:   Definition of term.
```

`tests/degrade/lineblock.md`:
```
| A line
| Second line
```

`tests/degrade/smallcaps.md`:
```
[abc]{.smallcaps}
```

`tests/degrade/subsup.md`:
```
H~2~O and x^2^
```

`tests/degrade/nested-table.md`:
```
+---------+
| - a     |
|   - b   |
+---------+
```

- [ ] **Step 4: Register the suite**

Add `"degrade_test"` to `suites` in `tests/run.lua`.

- [ ] **Step 5: Run and iterate until green**

Run: `pandoc lua tests/run.lua`
Expected: PASS. Adjust `notion/writer/blocks.lua` and `notion/writer/inlines.lua` fallbacks until each assertion holds.

- [ ] **Step 6: Commit**

```bash
git add tests/degrade tests/degrade_test.lua tests/support/nfm.lua tests/run.lua
git commit -m "test: pin lossy-input fallbacks and log levels"
```

---

### Task 12: Writer completeness test

Replaces the loud-failure guarantee lost by not using `pandoc.scaffolding.Writer`. Pandoc's constructors are not enumerable at runtime, so the list is explicit and pinned.

**Files:**
- Create: `tests/completeness_test.lua`
- Modify: `notion/writer/blocks.lua` and `notion/writer/inlines.lua` (add any missing handlers)
- Modify: `tests/run.lua`

**Interfaces:**
- Consumes: `notion.writer.blocks.handlers`, `notion.writer.inlines.handlers`.
- Produces: nothing new.

- [ ] **Step 1: Write the failing test**

Create `tests/completeness_test.lua`:

```lua
local t  = require "support.assert"
local wb = require "notion.writer.blocks"
local wi = require "notion.writer.inlines"

-- Pandoc does not expose its constructors as enumerable tables, so this list
-- is explicit and pinned to PANDOC_API_VERSION 1.23.1.2.
local BLOCKS = {
  "BlockQuote", "BulletList", "CodeBlock", "DefinitionList", "Div", "Figure",
  "Header", "HorizontalRule", "LineBlock", "OrderedList", "Para", "Plain",
  "RawBlock", "Table",
}

local INLINES = {
  "Cite", "Code", "Emph", "Image", "LineBreak", "Link", "Math", "Note",
  "Quoted", "RawInline", "SmallCaps", "SoftBreak", "Space", "Span", "Str",
  "Strikeout", "Strong", "Subscript", "Superscript", "Underline",
}

for _, name in ipairs(BLOCKS) do
  t.truthy(wb.handlers[name] ~= nil, "writer handles Block " .. name)
end
for _, name in ipairs(INLINES) do
  t.truthy(wi.handlers[name] ~= nil, "writer handles Inline " .. name)
end

t.eq(#BLOCKS, 14, "block constructor list is complete for this pandoc version")
t.eq(#INLINES, 20, "inline constructor list is complete for this pandoc version")
```

- [ ] **Step 2: Register the suite**

Add `"completeness_test"` to `suites` in `tests/run.lua`.

- [ ] **Step 3: Run the test**

Run: `pandoc lua tests/run.lua`

Expected: **PASS.** Unlike the other tasks, this test is not expected to fail
first. Tasks 8 and 9 already define all 34 handlers, so this is a *regression
guard*: it exists to fail in the future, when someone adds a construct or bumps
pandoc. If it fails now, a handler is genuinely missing — add it with a
deliberate, documented fallback from spec §8, never a stub that returns `""`.

- [ ] **Step 4: Verify the guard actually guards**

A completeness test that cannot fail is worthless, so prove it fails. Comment
out the `Strikeout` handler in `notion/writer/inlines.lua`:

```lua
  -- Strikeout  = function(el) return "~~" .. render(el.content) .. "~~" end,
```

Run: `pandoc lua tests/run.lua`
Expected: FAIL with `writer handles Inline Strikeout`.

Then restore the line and re-run.

- [ ] **Step 5: Run to confirm it passes again**

Run: `pandoc lua tests/run.lua`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add tests/completeness_test.lua notion/writer tests/run.lua
git commit -m "test: assert writer covers every pandoc constructor"
```

---

### Task 13: Official documentation fixtures, cross-format regression, and README

Closes the loop on the spec's requirement that both Notion doc pages are normative. This is the task that would have caught `<unknown>` and `<meeting-notes>`, so it is where the tag vocabulary gets its final check.

**Files:**
- Create: `tests/corpus/official/*.nfm`
- Create: `tests/crossformat_test.lua`
- Modify: `tests/roundtrip_test.lua` (add `official` with stability-only assertions)
- Modify: `README.md`
- Modify: `tests/run.lua`

**Interfaces:**
- Consumes: everything built so far.
- Produces: nothing new.

- [ ] **Step 1: Create the official fixtures**

Transcribe every example from the two Notion documentation pages verbatim.

`tests/corpus/official/complete-example.nfm` — the "Complete example" from the enhanced-markdown guide:
```
# Project kickoff {color="blue"}
<callout icon="🎯" color="blue_bg">
	Ship the MVP by **Friday**.
</callout>
- [x] Write spec
- [ ] Build prototype
- [ ] Collect feedback
```python
def greet(name):
    return f"Hello, {name}!"
```
<table>
	<tr>
		<td>Status</td>
		<td>Owner</td>
	</tr>
	<tr>
		<td>In progress</td>
		<td><mention-user url="{{user://abc123}}">Ada</mention-user></td>
	</tr>
</table>
```

`tests/corpus/official/meeting-notes-payload.nfm` — the payload used throughout the working-with-markdown page, which is the canonical demonstration of single-newline block separation:
```
# Meeting Notes
Discussed roadmap priorities.
## Action items
- [ ] Draft proposal
- [ ] Schedule follow-up
```

`tests/corpus/official/truncated-page.nfm` — from the truncation example:
```
# Large Document
First section content...
<unknown url="https://notion.com/abc123#def456"/>
```

`tests/corpus/official/block-type-support.nfm` — one line per row of the "Supported block types" table, proving the whole documented vocabulary parses:
```
Plain text paragraph
# Heading one
## Heading two
### Heading three
#### Heading four
- Bulleted item
1. Numbered item
- [ ] To do item
<details>
	<summary>
		Toggle
	</summary>
	Toggle body
</details>
> Quote text
<callout icon="i">
	Callout text
</callout>
---
$$a = b$$
![Image caption](https://example.com/i.png)
<file src="https://example.com/f.zip">File</file>
<video src="https://example.com/v.mp4">Video</video>
<audio src="https://example.com/a.mp3">Audio</audio>
<pdf src="https://example.com/d.pdf">PDF</pdf>
<page url="https://notion.so/p">Child page</page>
<database url="https://notion.so/d">Child database</database>
<synced_block url="https://notion.so/s">
	Synced
</synced_block>
<columns>
	<column>
		Column body
	</column>
</columns>
<table_of_contents/>
<meeting-notes>
	Transcript
</meeting-notes>
```

- [ ] **Step 2: Extend the round-trip test for official fixtures**

In `tests/roundtrip_test.lua`, append after the existing loop:

```lua
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
```

- [ ] **Step 3: Write the cross-format regression test**

Create `tests/crossformat_test.lua`:

```lua
local t   = require "support.assert"
local nfm = require "support.nfm"

local READER = nfm.ROOT .. "/notion-markdown-reader.lua"

-- Columns adopt pandoc's own convention, so they must survive into reveal.js
-- as a real two-column slide. This protects interoperability we got for free.
local columns = table.concat({
  "<columns>", "\t<column>", "\t\tLeft", "\t</column>",
  "\t<column>", "\t\tRight", "\t</column>", "</columns>", "" }, "\n")

local html = pandoc.pipe("pandoc", { "-f", READER, "-t", "revealjs" }, columns)
t.truthy(html:find('class="columns"', 1, true) ~= nil, "columns class survives to reveal.js")
t.truthy(html:find('class="column"', 1, true) ~= nil, "column class survives to reveal.js")

-- Conversion to common formats must not crash and must keep the content.
for _, fmt in ipairs({ "html", "gfm", "org", "latex", "plain" }) do
  local ok, out = pcall(pandoc.pipe, "pandoc", { "-f", READER, "-t", fmt }, columns)
  t.truthy(ok, "converts to " .. fmt .. " without error")
  if ok then
    t.truthy(out:find("Left", 1, true) ~= nil, "content survives conversion to " .. fmt)
  end
end

-- A callout's content must remain visible in other formats, which is the whole
-- reason the convention is structural rather than raw.
local callout = '<callout icon="X" color="blue_bg">\n\tVisible text\n</callout>\n'
local as_html = pandoc.pipe("pandoc", { "-f", READER, "-t", "html" }, callout)
t.truthy(as_html:find("Visible text", 1, true) ~= nil, "callout content survives to HTML")
t.truthy(as_html:find("callout", 1, true) ~= nil, "callout class survives to HTML")
```

- [ ] **Step 4: Register the suite**

Add `"crossformat_test"` to `suites` in `tests/run.lua`.

- [ ] **Step 5: Run to verify it fails, then iterate to green**

Run: `pandoc lua tests/run.lua`
Expected: FAIL initially on the official fixtures. Fix the reader/writer until
every assertion holds. A failure here most likely means a tag in the documented
vocabulary is missing from `notion/schema.lua`.

- [ ] **Step 6: Update the README**

Replace `README.md` with usage documentation:

````markdown
# Pandoc Notion Filters

Pandoc custom readers and writers for [Notion Flavored Markdown][nfm] (NFM),
the enhanced markdown dialect spoken by Notion's markdown API endpoints.

## Requirements

pandoc 3.10.2 or later. No other dependencies.

## Install

Copy this directory somewhere and invoke the entry points by real path:

```bash
git clone <this repo> ~/.local/share/pandoc-notion
```

Note: invoke by real path, not through a symlink. Pandoc reports the symlink
path in `PANDOC_SCRIPT_FILE`, so the sibling `notion/` modules would not be
found.

## Usage

```bash
# Notion markdown -> anything
pandoc -f ~/.local/share/pandoc-notion/notion-markdown-reader.lua \
       -t docx page.nfm -o page.docx

# Anything -> Notion markdown
pandoc -f docx -t ~/.local/share/pandoc-notion/notion-markdown-writer.lua \
       report.docx

# Round-trip (useful for verifying fidelity)
pandoc -f ...notion-markdown-reader.lua -t ...notion-markdown-writer.lua page.nfm
```

## AST convention

Notion constructs are represented structurally, as `Div` and `Span` with
classes and attributes, so content stays visible in every output format and
traversable by other Lua filters. See the design document for the full mapping
table: `docs/superpowers/specs/2026-08-28-notion-flavored-markdown-design.md`.

Where pandoc already had a convention, this project adopts it rather than
inventing one — columns (`Div class="columns"`), task lists (☐/☒ prefixes),
emoji, `Underline`, `Figure`, and math are all native.

## Lossy conversion

Constructs Notion cannot express are degraded deterministically and silently,
matching how pandoc's own writers behave. `[INFO]` is logged (visible under
`--verbose`) only when content is genuinely dropped. Fallbacks are NFM-native
rather than raw HTML, because NFM's HTML vocabulary is a closed set.

## Tests

```bash
pandoc lua tests/run.lua
```

## Not yet implemented

`notion-block-reader` and `notion-block-writer`, which convert Notion's block
object JSON to and from the pandoc AST. They are a separate sub-project and
will target the same AST convention, at which point NFM ↔ block-JSON
conversion falls out of piping through pandoc.

[nfm]: https://developers.notion.com/guides/data-apis/enhanced-markdown
````

- [ ] **Step 7: Run the full suite one final time**

Run: `pandoc lua tests/run.lua`
Expected: PASS, with no failures across all suites.

- [ ] **Step 8: Commit**

```bash
git add tests/corpus/official tests/crossformat_test.lua tests/roundtrip_test.lua \
        README.md tests/run.lua
git commit -m "test: add official Notion doc fixtures and cross-format checks"
```

---

### Task 14: AST golden files

Implements spec §9.3. Round-trip idempotence (Task 10) proves the reader and
writer agree with each other; it cannot notice if they *both* drift. Goldens
pin the §4 convention itself, so renaming a class or dropping an attribute
fails loudly instead of round-tripping happily.

**Files:**
- Create: `tests/regenerate_goldens.lua`
- Create: `tests/golden/**/*.native` (one per corpus fixture, generated)
- Create: `tests/golden_test.lua`
- Modify: `tests/run.lua`

**Interfaces:**
- Consumes: `tests/support/nfm.lua` (`to_native`, `list`, `read_file`).
- Produces: nothing new.

- [ ] **Step 1: Write the regeneration script**

Create `tests/regenerate_goldens.lua`. Goldens are generated, never
hand-written, but they are reviewed in the diff before committing:

```lua
local dir = (arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/../?.lua;" .. dir .. "/?.lua;" .. package.path

local nfm = require "support.nfm"

local SUBDIRS = { "blocks", "inlines", "nesting", "adversarial", "official" }
local written = 0

for _, sub in ipairs(SUBDIRS) do
  os.execute("mkdir -p " .. nfm.ROOT .. "/tests/golden/" .. sub)
  for _, path in ipairs(nfm.list(sub)) do
    local name = path:match("([^/]+)%.nfm$")
    local out  = nfm.to_native(nfm.read_file(path))
    local dest = nfm.ROOT .. "/tests/golden/" .. sub .. "/" .. name .. ".native"
    local fh = assert(io.open(dest, "wb"))
    fh:write(out)
    fh:close()
    written = written + 1
  end
end

print(string.format("wrote %d golden files", written))
```

- [ ] **Step 2: Write the failing test**

Create `tests/golden_test.lua`:

```lua
local t   = require "support.assert"
local nfm = require "support.nfm"

local SUBDIRS = { "blocks", "inlines", "nesting", "adversarial", "official" }
local checked = 0

for _, sub in ipairs(SUBDIRS) do
  for _, path in ipairs(nfm.list(sub)) do
    local name = path:match("([^/]+)%.nfm$")
    local dest = nfm.ROOT .. "/tests/golden/" .. sub .. "/" .. name .. ".native"
    local fh = io.open(dest, "rb")
    if not fh then
      t.truthy(false, "missing golden for " .. sub .. "/" .. name
                      .. " (run: pandoc lua tests/regenerate_goldens.lua)")
    else
      local expected = fh:read("a"); fh:close()
      t.eq(nfm.to_native(nfm.read_file(path)), expected,
           "AST matches golden: " .. sub .. "/" .. name)
      checked = checked + 1
    end
  end
end

t.truthy(checked >= 43, "every fixture has a golden, checked " .. checked)
```

- [ ] **Step 3: Register the suite**

Add `"golden_test"` to `suites` in `tests/run.lua`.

- [ ] **Step 4: Run to verify it fails**

Run: `pandoc lua tests/run.lua`
Expected: FAIL — `missing golden for blocks/paragraph`

- [ ] **Step 5: Generate the goldens and review them**

```bash
pandoc lua tests/regenerate_goldens.lua
git diff --stat tests/golden
```

Read several goldens before committing. Each must show the §4 convention:
`callout.native` should contain `Div ("",["callout"],[("icon",…),("color",…)])`,
and `paragraph.native` should show a bare `Para` for the unattributed line and a
class-less attribute `Div` for the colored one. A golden that looks wrong means
the code is wrong — regenerating does not make it right.

- [ ] **Step 6: Run to verify it passes**

Run: `pandoc lua tests/run.lua`
Expected: PASS

- [ ] **Step 7: Verify the goldens actually guard**

Temporarily change `callout` to `callout-x` in `notion/schema.lua`'s
`BLOCK_TAGS`, then run `pandoc lua tests/run.lua`. Expected: FAIL on
`AST matches golden: blocks/callout`. Restore the name and re-run.

- [ ] **Step 8: Commit**

```bash
git add tests/golden tests/golden_test.lua tests/regenerate_goldens.lua tests/run.lua
git commit -m "test: pin the AST convention with golden files"
```

---

### Task 15: Batch inline parsing

Implements spec §6.3. Because a single newline separates blocks, a document of
N text lines currently makes N separate `pandoc.read` calls — each a full
parser invocation. This batches them into one. Correctness never depends on the
optimization: the fallback path is exercised by test.

Deliberately last: optimize only once behavior is pinned by Tasks 10 and 14,
which together will prove the optimization changed no output.

**Files:**
- Modify: `notion/reader/inlines.lua`
- Modify: `notion/reader/blocks.lua`
- Create: `tests/unit/batching_test.lua`
- Modify: `tests/run.lua`

**Interfaces:**
- Consumes: existing modules.
- Produces: added to `notion/reader/inlines.lua`:
  - `prime(texts)` — parses many inline runs in one `pandoc.read`, caching results
  - `reset()` — clears the cache (called per document)
  - `read(text)` — unchanged signature; consults the cache first

- [ ] **Step 1: Write the failing test**

Create `tests/unit/batching_test.lua`:

```lua
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
```

- [ ] **Step 2: Register the suite**

Add `"unit.batching_test"` to `suites` in `tests/run.lua`.

- [ ] **Step 3: Run to verify it fails**

Run: `pandoc lua tests/run.lua`
Expected: FAIL — `attempt to call a nil value (field 'prime')`

- [ ] **Step 4: Implement priming in `notion/reader/inlines.lua`**

Replace the existing `M.read` with the cache-aware version, and add `prime` and
`reset` above it:

```lua
local cache = {}

function M.reset() cache = {} end

-- Parse many inline runs in ONE pandoc.read. Chunks are joined with a blank
-- line so pandoc keeps them as separate Paras, then mapped back positionally.
-- If the block count does not match, the batch is discarded entirely and the
-- per-chunk path is used, so correctness never depends on this working.
function M.prime(texts)
  if #texts == 0 then return end
  local joined = table.concat(texts, "\n\n")
  local doc = pandoc.read(joined, M.EXTENSIONS)
  if #doc.blocks ~= #texts then return end     -- misaligned: fall back silently
  for i, text in ipairs(texts) do
    local block = doc.blocks[i]
    if block.content then
      cache[text] = fold_citations(M.fold(block.content))
    end
  end
end

function M.read(text)
  local hit = cache[text]
  if hit then return hit end
  local doc = pandoc.read(text, M.EXTENSIONS)
  local ils = pandoc.utils.blocks_to_inlines(doc.blocks)
  local result = fold_citations(M.fold(ils))
  cache[text] = result
  return result
end
```

Note `fold_citations` must be declared before `prime`; move its definition
above if the file currently defines it later.

- [ ] **Step 5: Collect leaf texts in `notion/reader/blocks.lua`**

Add a pre-walk that gathers every leaf inline run, and call it from `convert`
at the top level. Add above `M.convert = convert`:

```lua
-- Gather every leaf inline run in the tree so they can be parsed in one pass.
local function gather(nodes, acc)
  for _, node in ipairs(nodes) do
    if node.kind ~= "code" then
      local _, content = nil, nil
      if node.kind == "text" then _, content = list_item(node.text) end
      acc[#acc + 1] = content or node.text
    end
    gather(node.children, acc)
  end
  return acc
end

-- Entry point used by the reader: prime the inline cache, then convert.
function M.convert_document(nodes)
  inlines.reset()
  inlines.prime(gather(nodes, {}))
  return convert(nodes)
end
```

- [ ] **Step 6: Point the reader entry at the batched path**

In `notion-markdown-reader.lua`, change the `Reader` body:

```lua
function Reader(input, opts)
  return pandoc.Pandoc(blocks.convert_document(tree.parse(tostring(input))))
end
```

- [ ] **Step 7: Run the full suite**

Run: `pandoc lua tests/run.lua`

Expected: PASS, including every round-trip and golden test from Tasks 10, 13
and 14 — unchanged. Those suites are what prove the optimization is invisible.
If a golden changes, the batching is wrong; do not regenerate the golden.

- [ ] **Step 8: Commit**

```bash
git add notion/reader/inlines.lua notion/reader/blocks.lua \
        notion-markdown-reader.lua tests/unit/batching_test.lua tests/run.lua
git commit -m "perf: parse all inline runs in a single pandoc.read"
```

---

## Verification Checklist

Run after Task 15. Each maps to a spec §11 success criterion.

- [ ] `pandoc lua tests/run.lua` exits 0 with zero failures.
- [ ] Every fixture in `tests/corpus/{blocks,inlines,nesting,adversarial}` round-trips byte-identically.
- [ ] Every fixture in `tests/corpus/official` is stable under repeated conversion.
- [ ] Every row of spec §4.3 and §4.4 has a corpus fixture and a golden file.
- [ ] Every pandoc `Block` and `Inline` constructor has a writer handler.
- [ ] Approximations log nothing at default verbosity; true drops log `[INFO]`.
- [ ] NFM `<columns>` converts to a reveal.js two-column slide.
- [ ] `tests/corpus/official/truncated-page.nfm`, which contains `<unknown>`, parses without error.
- [ ] The suite passes five times in a row (`for i in 1 2 3 4 5; do pandoc lua tests/run.lua; done`). Attribute ordering is the one place non-determinism could hide, so a single green run is not sufficient evidence.

## Spec Coverage Map

| Spec section | Task(s) |
|---|---|
| §4 AST convention | 3, 7, 9 |
| §4.2 attribute gap rule | 7, 9 |
| §5.1 packaging prelude | 7, 9 |
| §5.2 module layout | all |
| §6.1 pinned extension set | 6 |
| §6.2 tree (classify, nest) | 4, 5 |
| §6.3 blocks + batched reads | 7, 15 |
| §6.4 inline folding | 6 |
| §6.5 malformed input recovery | 5 |
| §7 writer design | 8, 9 |
| §8 lossy input policy | 8, 9, 11 |
| §9.1 tree unit tests | 4, 5 |
| §9.2 round-trip idempotence | 10 |
| §9.3 AST goldens | 14 |
| §9.4 completeness | 12 |
| §9.5 degradation | 11 |
| §9.6 cross-format regression | 13 |
| §9.7 corpus | 10, 13 |
| §11 success criteria | Verification Checklist |
