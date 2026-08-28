local inl    = require "notion.writer.inlines"
local schema = require "notion.schema"
local attr   = require "notion.attr"

local M = {}

local render      -- forward declaration

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
-- trailing `{…}` prose suffix: `attr.render` gives ` {k="v"}`; this strips
-- the braces (keeping the leading space) so callers can write `<tag k="v">`.
local function tag_attrs(a, order)
  return attr.render(a, order):gsub("^ {", " "):gsub("}$", "")
end

local function tag_attrs_of(attributes)
  local a, order = attr.from_attr(attributes)
  if #order == 0 then return "" end
  return tag_attrs(a, order)
end

-- Render a tag block: <tag k="v">\n\t<children>\n</tag>
-- Source order wins; def.attrs only supplies an order for documents that did
-- not come from NFM in the first place.
local function tag_block(tag, def, el, depth)
  local a, order = attr.from_attr(el.attributes)
  if #order == 0 then order = def.attrs end
  local body = tag_attrs(a, order)
  local open = "<" .. tag .. body
  if def.void then return tabs(depth) .. open .. "/>" end
  local kids = render(el.content, depth + 1)
  if kids == "" then return tabs(depth) .. open .. "></" .. tag .. ">" end
  return tabs(depth) .. open .. ">\n" .. kids .. "\n" .. tabs(depth) .. "</" .. tag .. ">"
end

-- Render the children of an unwrapped Div (attribute-only, or toggle-heading)
-- back the way reader/blocks.lua produced them: the first block is the line
-- the Div's own attrs/class rode on, so it stays at `depth`; any further
-- blocks were tab-indented children of that source line one level deeper.
local function unwrap_children(content, depth)
  if #content == 0 then return "" end
  local head = render(pandoc.Blocks({ content[1] }), depth)
  if #content == 1 then return head end
  local rest = pandoc.Blocks({})
  for i = 2, #content do rest:insert(content[i]) end
  return head .. "\n" .. render(rest, depth + 1)
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

  -- unknown class: render the children, losing only the wrapper
  return render(el.content, depth)
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
    local body = render(pandoc.Blocks(item), depth + 1)
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
    return tabs(d) .. string.rep("#", math.min(el.level, 4)) .. " "
           .. inl.render(el.content) .. attr_suffix(el.attributes)
  end,

  BlockQuote = function(el, d)
    local body = render(el.content, 0):gsub("\n", "<br>")
    return tabs(d) .. "> " .. body
  end,

  BulletList  = function(el, d) return list(el, d, "- ") end,
  OrderedList = function(el, d) return list(el, d, function(i) return i .. ". " end) end,

  CodeBlock = function(el, d)
    local lang = el.classes[1] or ""
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
    return tabs(d) .. "![" .. caption .. "](" .. src .. ")"
  end,

  Table = function(el, d)
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

    return tabs(d) .. "<table" .. tag_attrs(out_pairs, out_order)
           .. ">\n" .. table.concat(rows, "\n") .. "\n" .. tabs(d) .. "</table>"
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

-- Footnotes: NFM has none. A Note is replaced with a `[n]` marker wherever it
-- appears, and its body collected as an endnote appended after the blocks
-- that contained it. `walk` recurses through the whole given subtree (Divs,
-- lists, tables, …) in one pass, so nested `render` calls simply see an
-- already-marked, note-free tree and find nothing further to collect.
local function extract_notes(blocks)
  local notes, n = {}, 0
  local marked = pandoc.Blocks(blocks):walk({
    Note = function(el)
      n = n + 1
      notes[#notes + 1] = { index = n, blocks = el.content }
      return pandoc.Str("[" .. n .. "]")
    end,
  })
  return marked, notes
end

render = function(blocks, depth)
  local marked, notes = extract_notes(blocks or {})
  local out = {}
  for _, b in ipairs(marked) do
    local h = handlers[b.t]
    local text
    if h then text = h(b, depth or 0)
    else text = (depth and tabs(depth) or "") .. pandoc.utils.stringify(b) end
    if text ~= "" then out[#out + 1] = text end
  end
  for _, note in ipairs(notes) do
    out[#out + 1] = "[" .. note.index .. "] " .. render(note.blocks, 0)
  end
  return table.concat(out, "\n")     -- single newline between blocks
end

function M.render_document(doc)
  return render(doc.blocks, 0)
end

M.render = render
M.handlers = handlers
return M
