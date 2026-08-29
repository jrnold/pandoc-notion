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
    -- Lua's \ddd escape caps at \255, so these must be \u{...} escapes; a
    -- Lua pattern character class also cannot hold a multibyte character,
    -- which is why the two boxes are matched as separate literal prefixes
    -- above rather than as a %[\u{2610}\u{2612}%]-style class.
    local box = (todo == " ") and "\u{2610}" or "\u{2612}"
    return "bullet", box .. " " .. rest
  end
  local bullet = text:match("^%-%s(.*)$")
  if bullet then return "bullet", bullet end
  local ordered = text:match("^%d+%.%s(.*)$")
  if ordered then return "ordered", ordered end
  return nil
end

-- A tag_inline node's `text` is the whole raw line, e.g. `<td>Cell</td>` or
-- `<callout icon="X">Hi</callout>`. Extract just the inner content.
local function inline_label(text)
  return text:match("^<[%w_%-]+.->(.*)</[%w_%-]+>%s*$") or ""
end

-- The single source of truth for "what string does this node hand to
-- inlines.read()", or nil for a node that never calls it (code, display
-- math, divider, self-closing tags, "table"/"tag_open" container nodes
-- whose children are read separately). block_for() below and gather()
-- further down BOTH call this -- neither recomputes its own prefix-
-- stripping -- so the batching cache's priming key and the key block_for
-- actually looks up can never drift apart the way they once did.
--
-- Deliberately NOT special-cased here: "td". Unlike every other tag, a
-- <td>'s read text depends on CONTEXT, not on the node alone -- inside a
-- real <table> it is a cell (see cell_text below); outside one it is not a
-- cell at all, and per block_for()'s own fallthrough (a "td" tag matches
-- none of TABLE_TAGS/BLOCK_TAGS/MEDIA_TAGS/MENTION_TAGS here) it must read
-- like ordinary literal text, node.text unchanged, same as any other
-- unrecognised tag.
local function leaf_text(node)
  if node.kind == "code" then return nil end

  if node.kind == "text" then
    local _, content = list_item(node.text)
    if content then return content end
  end

  if node.kind == "tag_open" or node.kind == "self_closing" or node.kind == "tag_inline" then
    local tag = node.tag
    if tag == "table" then return nil end
    if schema.BLOCK_TAGS[tag] then
      return node.kind == "tag_inline" and inline_label(node.text) or nil
    end
    if schema.MEDIA_TAGS[tag] then return inline_label(node.text) end
    if schema.MENTION_TAGS[tag] then return node.text end
    -- unknown tag (this includes a stray "td", "tr", "colgroup", or "col"
    -- reached outside a <table>): fall through to the generic text-pattern
    -- handling below, exactly as block_for()'s own fallthrough does for
    -- e.g. <unknown>.
  end

  local text = node.text
  if text == "---" then return nil end
  local hashes, htext = text:match("^(#+)%s(.*)$")
  if hashes and #hashes <= 6 then return htext end
  local eq = text:match("^%$%$(.*)%$%$$")
  if eq then return nil end
  local quote = text:match("^>%s?(.*)$")
  if quote then return quote end
  return text
end

-- The read text for a <td> WHEN READ AS A TABLE CELL (see cell_content and
-- table_block below, and gather()'s table-aware branch further down). This
-- is the one carve-out from leaf_text being the single source of truth:
-- whether a <td>'s tag wrapper is stripped depends on whether this node is
-- actually being walked as part of a real <table>'s rows, which only the
-- callers that do that walk can know.
local function cell_text(td)
  if td.kind == "tag_inline" then return inline_label(td.text) end
  return nil
end

-- A <colgroup>/<col> color has no home in pandoc's Table model -- ColSpec is
-- just {alignment, width}, with no Attr slot -- so it is genuinely dropped
-- rather than merely degraded. Spec §8 requires content that is actually
-- dropped (as opposed to silently approximated) to be logged at INFO,
-- phrased in pandoc's own style; column color is explicitly meaningful
-- content per §3.1's cell/row/column precedence. Log once per <col> that
-- carries a color; a colgroup with no colors logs nothing.
local function log_colgroup_colors(node)
  for _, child in ipairs(node.children) do
    if child.tag == "colgroup" then
      for _, col in ipairs(child.children) do
        if col.tag == "col" and col.attrs.color then
          pandoc.log.info("Not rendering column color (pandoc ColSpec has no attributes)")
        end
      end
    end
  end
end

-- A <td>'s inline content either arrives inline (`kind == "tag_inline"`,
-- text like `<td>Cell</td>`) or, when the cell spans multiple lines, as
-- CHILDREN of a "tag_open" td node with text just `<td>`. Cells hold rich
-- text only (never block content), so in the multi-line case the children
-- are converted to Blocks and then flattened with blocks_to_inlines rather
-- than kept as blocks -- the same flattening inlines.read itself does.
local function cell_content(td)
  if td.kind == "tag_inline" then
    return inlines.read(cell_text(td))
  end
  return pandoc.utils.blocks_to_inlines(children_of(td))
end

-- Build one <table> node into a native pandoc Table/Row/Cell. A
-- <colgroup>/<col> child, if present, is simply not a <tr>, so the loop
-- below already skips it when gathering rows; any color it carries is
-- logged above and then discarded, per the ruling in log_colgroup_colors.
local function table_block(node)
  log_colgroup_colors(node)

  local trs = {}
  for _, child in ipairs(node.children) do
    if child.tag == "tr" then trs[#trs + 1] = child end
  end

  local ncols = 0
  local rows = {}
  for _, tr in ipairs(trs) do
    local cells = {}
    for _, td in ipairs(tr.children) do
      if td.tag == "td" then
        cells[#cells + 1] = pandoc.Cell(
          pandoc.Blocks({ pandoc.Plain(cell_content(td)) }),
          pandoc.AlignDefault, 1, 1, attr_of(td))
      end
    end
    if #cells > ncols then ncols = #cells end
    rows[#rows + 1] = pandoc.Row(cells, attr_of(tr))
  end

  local colspecs = {}
  for i = 1, ncols do colspecs[i] = { pandoc.AlignDefault, nil } end

  -- header-row="true" moves the first row into the table head; otherwise
  -- the head is empty and every row stays in the body.
  local head_rows, body_rows = {}, rows
  if node.attrs["header-row"] == "true" and #rows > 0 then
    head_rows = { rows[1] }
    body_rows = {}
    for i = 2, #rows do body_rows[#body_rows + 1] = rows[i] end
  end

  -- header-column="true" has a real native slot: TableBody's row_head_columns.
  local row_head_columns = node.attrs["header-column"] == "true" and 1 or 0

  -- Table-level attributes other than header-row/header-column (e.g.
  -- fit-page-width) go on the Table's own Attr.
  local a, order = {}, {}
  for _, k in ipairs(node.attr_order) do
    if k ~= "header-row" and k ~= "header-column" then
      a[k] = node.attrs[k]; order[#order + 1] = k
    end
  end

  -- Single-argument pandoc.Caption(long) yields `Caption Nothing […]`,
  -- matching what pandoc's own readers emit; the two-argument form is not
  -- usable here (see the media Figure comment above).
  return pandoc.Table(
    pandoc.Caption({}),
    colspecs,
    pandoc.TableHead(head_rows, pandoc.Attr()),
    { pandoc.TableBody(body_rows, {}, row_head_columns, pandoc.Attr()) },
    pandoc.TableFoot({}, pandoc.Attr()),
    pandoc.Attr("", {}, attr.ordered(a, order)))
end

local function block_for(node)
  local kind = node.kind

  if kind == "code" then
    local classes = node.info ~= "" and { node.info } or {}
    return pandoc.CodeBlock(node.text, attr_of(node, classes))
  end

  if kind == "tag_open" or kind == "self_closing" or kind == "tag_inline" then
    local tag = node.tag
    -- Ruling F1: <table>/<tr>/<td> become native Table/Row/Cell, not a Div;
    -- this branch must run before the BLOCK_TAGS/MEDIA_TAGS lookups below,
    -- neither of which know about "table".
    if tag == "table" then
      return table_block(node)
    end
    local def = schema.BLOCK_TAGS[tag]
    if def then
      local kids = children_of(node)
      if kind == "tag_inline" then
        kids = pandoc.Blocks({ pandoc.Plain(inlines.read(leaf_text(node))) })
      end
      return pandoc.Div(kids, attr_of(node, { def.class }))
    end
    local media = schema.MEDIA_TAGS[tag]
    if media then
      local caption = inlines.read(leaf_text(node))
      local src = node.attrs.src or ""
      local body = pandoc.Blocks({
        pandoc.Plain({ pandoc.Link(caption, src) }) })
      -- src moves onto the inner Link, so drop it from the Figure's own attrs
      -- while keeping the source order of everything else.
      local a, order = {}, {}
      for _, k in ipairs(node.attr_order) do
        if k ~= "src" then a[k] = node.attrs[k]; order[#order + 1] = k end
      end
      -- pandoc.Caption(short, long) types `short` as Inlines: passing nil for
      -- it still crashes (`object has no __toinline metamethod`) on this
      -- pandoc version. The single-argument form -- long only -- both avoids
      -- the crash and produces `Caption Nothing […]`, matching what pandoc's
      -- own readers emit for an unlabelled caption.
      return pandoc.Figure(body, pandoc.Caption(pandoc.Blocks({ pandoc.Plain(caption) })),
                           pandoc.Attr("", { media.class }, attr.ordered(a, order)))
    end
    -- A standalone <mention-*> line: BLOCK_TAGS/MEDIA_TAGS/table don't know
    -- it, so without this branch it would fall through to the generic
    -- paragraph path below. inlines.read(node.text) already builds the
    -- mention Span with its own Attr straight from the tag's attribute
    -- list, so node.attrs must NOT also be applied here via wrap() -- doing
    -- so double-emits the same attributes as a redundant attribute Div
    -- wrapper around the Para (which the writer then renders as a stray
    -- trailing `{...}` on the line). Table tags are handled above and
    -- BLOCK_TAGS/MEDIA_TAGS are the only other known-tag kinds, so mentions
    -- are the only fallthrough case this needs to cover.
    if schema.MENTION_TAGS[tag] then
      return pandoc.Para(inlines.read(leaf_text(node)))
    end
  end

  local text = node.text

  if text == "---" then
    -- HorizontalRule has no Attr slot, so a divider color is genuinely
    -- dropped, not merely degraded -- log it per spec §8, same tier as
    -- log_colgroup_colors above.
    if next(node.attrs) ~= nil then
      pandoc.log.info("Not rendering divider color (HorizontalRule has no attributes)")
    end
    return pandoc.HorizontalRule()
  end

  local hashes, htext = text:match("^(#+)%s(.*)$")
  if hashes and #hashes <= 6 then
    local level = math.min(#hashes, 4)
    local header = pandoc.Header(level, inlines.read(leaf_text(node)), attr_of(node))
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
    local body = pandoc.Blocks({ pandoc.Para(inlines.read(leaf_text(node))) })
    for _, b in ipairs(children_of(node)) do body:insert(b) end
    return wrap(pandoc.BlockQuote(body), node)
  end

  -- ordinary paragraph, possibly with children
  local content = inlines.read(leaf_text(node))

  -- Spec §4.3: a standalone `![Caption](URL)` -- one Image and nothing
  -- else on the line -- becomes a Figure with a populated Caption, the same
  -- shape MEDIA_TAGS produce, rather than staying a Para. A line that mixes
  -- an image with other text stays a normal Para.
  if #node.children == 0 and #content == 1 and content[1].t == "Image" then
    local img = content[1]
    return pandoc.Figure(
      pandoc.Blocks({ pandoc.Plain({ img }) }),
      pandoc.Caption(pandoc.Blocks({ pandoc.Plain(img.caption) })),
      attr_of(node))
  end

  local para = pandoc.Para(content)
  if #node.children > 0 then
    local kids = pandoc.Blocks({ para })
    for _, b in ipairs(children_of(node)) do kids:insert(b) end
    return pandoc.Div(kids, attr_of(node))
  end
  return wrap(para, node)
end

-- Build a list item's blocks: its own content plus any nested children.
local function item_blocks(node)
  local first = pandoc.Plain(inlines.read(leaf_text(node)))
  local body  = pandoc.Blocks({ next(node.attrs) == nil and first
                                or pandoc.Div({ first }, attr_of(node)) })
  for _, b in ipairs(children_of(node)) do body:insert(b) end
  return body
end

convert = function(nodes)
  local out, i = pandoc.Blocks({}), 1
  while i <= #nodes do
    local node = nodes[i]
    local kind = nil
    if node.kind == "text" then kind = list_item(node.text) end

    if kind then
      -- gather the run of same-kind siblings into one list
      local items, j = {}, i
      while j <= #nodes do
        local nk = nil
        if nodes[j].kind == "text" then nk = list_item(nodes[j].text) end
        if nk ~= kind then break end
        items[#items + 1] = item_blocks(nodes[j])
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

-- Gather every leaf inline run in the tree so they can be parsed in one pass.
-- leaf_text() is the same function block_for() itself uses to decide what to
-- hand to inlines.read(), so the primed cache key and the lookup key can
-- never disagree -- except for a real <table>'s cells, whose read text is
-- context-dependent (see cell_text above): a "table" node's rows are walked
-- separately here, the same way table_block() walks them, using the
-- matching cell_text() rather than leaf_text()'s context-free (and for
-- "td", therefore wrong) fallback.
local function gather(nodes, acc)
  for _, node in ipairs(nodes) do
    if node.tag == "table" then
      for _, tr in ipairs(node.children) do
        if tr.tag == "tr" then
          for _, td in ipairs(tr.children) do
            if td.tag == "td" then
              local text = cell_text(td)
              if text then acc[#acc + 1] = text end
              gather(td.children, acc)
            end
          end
        end
      end
    else
      local text = leaf_text(node)
      if text then acc[#acc + 1] = text end
      gather(node.children, acc)
    end
  end
  return acc
end

-- Entry point used by the reader: prime the inline cache, then convert.
function M.convert_document(nodes)
  inlines.reset()
  inlines.prime(gather(nodes, {}))
  return convert(nodes)
end

M.convert = convert
return M
