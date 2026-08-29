local inl    = require "notion.writer.inlines"
local schema = require "notion.schema"
local attr   = require "notion.attr"

local M = {}

local render_inner   -- forward declaration; the pure recursive dispatcher.
                      -- Does NOT walk for notes -- that happens exactly once,
                      -- in render_with_notes below, before any dispatch.

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

-- Same attribute list, formatted for inside a tag's `< >` rather than as a
-- trailing `{…}` prose suffix. One shared definition (attr.tag_attrs), so it
-- cannot drift from writer/inlines.lua's copy of the same idea.
local tag_attrs = attr.tag_attrs

local function tag_attrs_of(attributes)
  return tag_attrs(attr.from_attr(attributes))
end

-- Same test writer/inlines.lua applies to a RawInline; imported rather than
-- copied so the two can never disagree about NFM's closed tag vocabulary.
local html_tag_name = inl.html_tag_name

-- Render a tag block. Two shapes, matching what reader/tree.lua's tag_kind
-- can actually parse back:
--   - a schema.CONTAINERS tag (callout, details, …): <tag k="v">\n\t…\n</tag>
--   - anything else (page, database): only ever built by the reader as
--     tag_inline, so it must round-trip as one line, <tag k="v">…</tag>.
--     tag_kind only opens a multi-line container for CONTAINERS tags; writing
--     the container form for, say, <page>, produces a tag_open the reader can
--     never close, corrupting the very next read.
local function tag_block(tag, def, el, depth)
  local body = tag_attrs_of(el.attributes)
  local open = "<" .. tag .. body
  if def.void then return tabs(depth) .. open .. "/>" end
  if not schema.CONTAINERS[tag] then
    local inline = inl.render(pandoc.utils.blocks_to_inlines(el.content))
    return tabs(depth) .. open .. ">" .. inline .. "</" .. tag .. ">"
  end
  local kids = render_inner(el.content, depth + 1)
  if kids == "" then return tabs(depth) .. open .. "></" .. tag .. ">" end
  return tabs(depth) .. open .. ">\n" .. kids .. "\n" .. tabs(depth) .. "</" .. tag .. ">"
end

-- Render the children of an unwrapped Div (attribute-only, or toggle-heading)
-- back the way reader/blocks.lua produced them: the first block is the line
-- the Div's own attrs/class rode on, so it stays at `depth`; any further
-- blocks were tab-indented children of that source line one level deeper.
local function unwrap_children(content, depth)
  if #content == 0 then return "" end
  local head = render_inner(pandoc.Blocks({ content[1] }), depth)
  if #content == 1 then return head end
  local rest = pandoc.Blocks({})
  for i = 2, #content do rest:insert(content[i]) end
  return head .. "\n" .. render_inner(rest, depth + 1)
end

local function div(el, depth)
  local classes = el.classes

  -- attribute-only Div: unwrap, pushing attributes onto the single child
  if #classes == 0 then
    local inner = unwrap_children(el.content, depth)
    local suffix = attr_suffix(el.attributes)
    if suffix == "" then return inner end
    -- attach to the first line only
    local first, rest = inner:match("^([^\n]*)(.*)$")
    return first .. suffix .. rest
  end

  if classes[1] == "toggle-heading" then
    return unwrap_children(el.content, depth)
  end

  local tag, kind = schema.class_to_tag(classes[1])
  if tag and kind == "block" then
    return tag_block(tag, schema.BLOCK_TAGS[tag], el, depth)
  end

  -- unknown class: not NFM's, and not produced by our own reader -- render
  -- the children, losing only the wrapper, and log it (a genuine drop).
  pandoc.log.info('Not rendering Div wrapper (class "' .. classes[1] .. '" is not part of NFM)')
  return render_inner(el.content, depth)
end

-- To-do items arrive as a Plain whose text starts with U+2610/U+2612 then a
-- space (F2: `\ddd` caps at \255, so these must be `\u{...}` escapes; F3: a
-- Lua pattern character class cannot hold a multibyte character, so the two
-- boxes are matched as separate literal prefixes rather than a
-- `[\u{2610}\u{2612}]`-style class).
local function todo_prefix(text)
  local rest = text:match("^\u{2610} (.*)$")
  if rest then return "[ ] ", rest end
  rest = text:match("^\u{2612} (.*)$")
  if rest then return "[x] ", rest end
  return nil, nil
end

local function list(el, depth, marker)
  local out = {}
  for i, item in ipairs(el.content) do
    local body = render_inner(pandoc.Blocks(item), depth + 1)
    -- first line carries the marker; the rest stays tab-indented
    local first, rest = body:match("^" .. tabs(depth + 1) .. "([^\n]*)(.*)$")
    first = first or body
    local m = type(marker) == "function" and marker(i) or marker
    local box, text = todo_prefix(first)
    if box then
      m = m .. box
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
    if el.level > 4 then
      pandoc.log.info("Not rendering heading level " .. el.level .. " (NFM only has levels 1-4)")
    end
    -- NFM headings carry an attribute list only -- there is no `{#id}` or
    -- `{.class}` syntax -- so an identifier or class is a genuine drop (Sec 8).
    if el.identifier ~= "" then
      pandoc.log.info('Not rendering heading identifier "' .. el.identifier
                      .. '" (NFM headings have no identifier)')
    end
    if #el.classes > 0 then
      pandoc.log.info('Not rendering heading class "' .. el.classes[1]
                      .. '" (NFM headings have no classes)')
    end
    return tabs(d) .. string.rep("#", math.min(el.level, 4)) .. " "
           .. inl.render(el.content) .. attr_suffix(el.attributes)
  end,

  BlockQuote = function(el, d)
    local body = render_inner(el.content, 0):gsub("\n", "<br>")
    return tabs(d) .. "> " .. body
  end,

  BulletList  = function(el, d) return list(el, d, "- ") end,
  OrderedList = function(el, d) return list(el, d, function(i) return i .. ". " end) end,

  CodeBlock = function(el, d)
    local lang = el.classes[1] or ""
    -- A fence info string holds one language, so any further class (e.g.
    -- pandoc's `.numberLines`) has nowhere to go: a genuine drop (Sec 8).
    for i = 2, #el.classes do
      pandoc.log.info('Not rendering code block class "' .. el.classes[i]
                      .. '" (an NFM fence info string holds one language)')
    end
    local suffix = attr_suffix(el.attributes)
    local body = {}
    for line in (el.text .. "\n"):gmatch("(.-)\n") do body[#body + 1] = tabs(d) .. line end
    return tabs(d) .. "```" .. lang .. suffix .. "\n" .. table.concat(body, "\n")
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
      local body = tag_attrs(a, order)
      return tabs(d) .. "<" .. class .. body .. ">" .. caption .. "</" .. class .. ">"
    end
    local src = ""
    pandoc.walk_block(el, { Image = function(i) src = i.src end })
    -- The attribute suffix is NOT optional here: reader/blocks.lua builds a
    -- standalone `![Cap](URL)` into a Figure carrying the line's own `{…}`
    -- attributes (spec Sec 4.3), exactly as the media branch above does, so
    -- omitting it silently loses e.g. a colour on the way back out.
    return tabs(d) .. "![" .. caption .. "](" .. src .. ")" .. attr_suffix(el.attributes)
  end,

  Table = function(el, d)
    -- NFM's <table> has no caption element at all, so a Caption is a genuine
    -- drop rather than an approximation (Sec 8).
    if #(el.caption.long or {}) > 0 then
      pandoc.log.info("Not rendering table caption (NFM tables have no caption)")
    end

    -- Table cells hold rich text only; block content in a cell is a true drop.
    local rows = {}
    local function emit_rows(section)
      for _, row in ipairs(section) do
        local cells = {}
        for _, cell in ipairs(row.cells) do
          local text = inl.render(pandoc.utils.blocks_to_inlines(cell.contents))
          for _, b in ipairs(cell.contents) do
            if b.t ~= "Plain" and b.t ~= "Para" then
              pandoc.log.info("Not rendering " .. b.t .. " inside table cell")
            end
          end
          cells[#cells + 1] = tabs(d + 2) .. "<td" .. tag_attrs_of(cell.attributes)
                               .. ">" .. text .. "</td>"
        end
        rows[#rows + 1] = tabs(d + 1) .. "<tr" .. tag_attrs_of(row.attributes) .. ">\n"
                          .. table.concat(cells, "\n")
                          .. "\n" .. tabs(d + 1) .. "</tr>"
      end
    end
    emit_rows(el.head.rows)
    for _, b in ipairs(el.bodies) do emit_rows(b.body) end

    -- header-row="true" / header-column="true" are peeled off the source
    -- <table …> tag by the reader (Task 7) into TableHead/row_head_columns;
    -- emit them back symmetrically, leading the table's own remaining
    -- attributes (in their original source order).
    local a, order = attr.from_attr(el.attributes)
    local out_pairs, out_order = {}, {}
    if #el.head.rows > 0 then
      out_pairs["header-row"] = "true"
      out_order[#out_order + 1] = "header-row"
    end
    local row_head_columns = 0
    for _, b in ipairs(el.bodies) do
      if b.row_head_columns > row_head_columns then row_head_columns = b.row_head_columns end
    end
    if row_head_columns > 0 then
      out_pairs["header-column"] = "true"
      out_order[#out_order + 1] = "header-column"
    end
    for _, k in ipairs(order) do
      out_pairs[k] = a[k]
      out_order[#out_order + 1] = k
    end

    local open = tabs(d) .. "<table" .. tag_attrs(out_pairs, out_order) .. ">"
    -- A table with no <tr> at all would otherwise get a blank line between
    -- its tags from the empty table.concat below.
    if #rows == 0 then return open .. "</table>" end
    return open .. "\n" .. table.concat(rows, "\n") .. "\n" .. tabs(d) .. "</table>"
  end,

  DefinitionList = function(el, d)
    local out = {}
    for _, entry in ipairs(el.content) do
      out[#out + 1] = tabs(d) .. "**" .. inl.render(entry[1]) .. "**"
      for _, def in ipairs(entry[2]) do
        out[#out + 1] = render_inner(pandoc.Blocks(def), d + 1)
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
    if el.format == "html" then
      local tag = html_tag_name(el.text)
      if tag and schema.is_known_tag(tag) then return tabs(d) .. el.text end
    end
    pandoc.log.info('Not rendering RawBlock (Format "' .. el.format .. '")')
    return ""
  end,
}

render_inner = function(blocks, depth)
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

-- Footnotes: NFM has none. A Note is replaced with a sentinel-wrapped marker
-- wherever it appears, and its body collected as an endnote appended after
-- the blocks that contained it. The sentinel (private-use-area characters,
-- never produced by any real text) survives inline rendering -- including
-- the Str handler's escaping of `[`/`]` -- untouched, because at the point it
-- is escaped it contains no bracket characters yet; the brackets are only
-- substituted in afterwards, so the in-text marker and the endnote label are
-- both literal, unescaped `[n]`, never `\[n\]`.
local MARK_OPEN, MARK_CLOSE = "\u{E000}", "\u{E001}"

local function extract_notes(blocks)
  local notes, n = {}, 0
  local marked = pandoc.Blocks(blocks):walk({
    Note = function(el)
      n = n + 1
      notes[#notes + 1] = { index = n, blocks = el.content }
      return pandoc.Str(MARK_OPEN .. n .. MARK_CLOSE)
    end,
  })
  return marked, notes
end

-- The one place `render`'s note-handling runs: `walk` above is deep, so a
-- single call here catches every Note anywhere in `blocks`, however deeply
-- nested inside Divs/lists/tables. Recursive rendering (render_inner) never
-- re-walks, which is what makes this O(nodes) rather than O(depth × nodes).
local function render_with_notes(blocks, depth)
  local marked, notes = extract_notes(blocks or {})
  local parts = { render_inner(marked, depth) }
  for _, note in ipairs(notes) do
    parts[#parts + 1] = MARK_OPEN .. note.index .. MARK_CLOSE .. " " .. render_inner(note.blocks, 0)
  end
  local result = table.concat(parts, "\n")
  return (result:gsub(MARK_OPEN .. "(%d+)" .. MARK_CLOSE, "[%1]"))
end

function M.render_document(doc)
  return render_with_notes(doc.blocks, 0)
end

M.render = render_with_notes
M.handlers = handlers
return M
