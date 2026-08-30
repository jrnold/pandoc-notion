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
  -- A leading '#' run that block_for() does NOT treat as a heading -- seven
  -- or more hashes, or no space after them -- is ordinary text. It still has
  -- to be handed to inlines.read backslash-escaped, because markdown_strict's
  -- own (looser) ATX rule reparses `####### seven` as a heading and
  -- blocks_to_inlines then flattens it to bare `seven`, eating the hashes
  -- with no error and no log. all_symbols_escapable is on, so the backslash
  -- is consumed and the '#' run survives verbatim. The writer never escapes
  -- '#' (it is not in escape.SPECIAL), so this round-trips byte-identically.
  if text:sub(1, 1) == "#" then return "\\" .. text end
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
  local kids = children_of(td)
  -- blocks_to_inlines keeps the text but discards the block wrapper, so a
  -- list or a nested table inside a cell loses its structure -- a genuine
  -- drop per Sec 8. The WRITE side already logs the identical drop (see the
  -- Table handler in writer/blocks.lua); logging it here too keeps one
  -- construct from being loud in one direction and silent in the other.
  for _, b in ipairs(kids) do
    if b.t ~= "Plain" and b.t ~= "Para" then
      pandoc.log.info("Not rendering " .. b.t .. " inside table cell")
    end
  end
  return pandoc.utils.blocks_to_inlines(kids)
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
        -- `<tag></tag>` written on ONE line has no body. Emitting Plain [] for
        -- it made an empty container read differently from the same container
        -- written across two lines (which yields no child at all), and the
        -- writer renders those two ASTs as two different texts -- an
        -- f(f(x)) ~= f(x) cycle alternating between the collapsed and expanded
        -- forms. An empty body is no content, however it was spelled.
        local body = leaf_text(node)
        if body and body ~= "" then
          kids = pandoc.Blocks({ pandoc.Plain(inlines.read(body)) })
        else
          kids = pandoc.Blocks({})
        end
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

  -- A KNOWN tag that reaches here is one no branch above claimed: a table
  -- structure tag (<td>, <tr>, <col>, <colgroup>) stray outside a real
  -- <table>. leaf_text() deliberately keeps such a node's text VERBATIM, so
  -- its attribute list is already present, literally, in the text below --
  -- applying node.attrs a second time (via wrap(), or on the children Div)
  -- double-emits them as a stray trailing `{…}`, the same bug the standalone
  -- mention branch above guards against.
  local verbatim = kind == "tag_open" or kind == "self_closing" or kind == "tag_inline"

  if text == "---" then
    -- HorizontalRule has no Attr slot, so a divider color is genuinely
    -- dropped, not merely degraded -- log it per spec §8, same tier as
    -- log_colgroup_colors above.
    if next(node.attrs) ~= nil then
      pandoc.log.info("Not rendering divider color (HorizontalRule has no attributes)")
    end
    return pandoc.HorizontalRule()
  end

  local hashes = text:match("^(#+)%s.*$")  -- body unused here
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
    return pandoc.Div(kids, verbatim and pandoc.Attr() or attr_of(node))
  end
  if verbatim then return para end
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

-- Does this cell's already-parsed content contain any of NFM's own tags
-- (<mention-*>, <span underline/color>, <br>)? pandoc.read (below) doesn't
-- know that vocabulary, so it leaves it as unfolded RawInline("html", …)
-- pairs rather than erroring -- this is the one signal that a cell needs
-- the fold_pipe_cell round trip at all.
local function cell_has_raw(ils)
  for _, il in ipairs(ils) do
    if il.t == "RawInline" then return true end
  end
  return false
end

-- Fold NFM's raw-HTML tag vocabulary inside one pipe-table cell's Inlines.
-- pandoc.read's own pipe_tables grammar already splits cells and parses
-- ordinary markdown inside them correctly -- through the same M.EXTENSIONS
-- inlines.read uses -- so the only gap is NFM's own tags, which arrive
-- unfolded (see cell_has_raw). Writing the cell back out as
-- markdown_strict+raw_html text and re-reading it through inlines.read
-- reuses that fold/citation logic exactly instead of duplicating it here.
-- Skipped entirely for the common case of a cell with no raw HTML at all.
local function fold_pipe_cell(ils)
  if not cell_has_raw(ils) then return ils end
  local text = pandoc.write(pandoc.Pandoc(pandoc.Blocks({ pandoc.Plain(ils) })),
                            "markdown_strict+raw_html")
  return inlines.read((text:gsub("\n+$", "")))
end

-- A rough, non-escape-aware upper bound on how many cells a pipe-table
-- source LINE declares: count the "|" characters after stripping one
-- optional leading and trailing "|", plus one. Used only to detect the
-- truncation pipe_table_run below guards against -- never to extract
-- actual cell text (fold_pipe_cell above, via pandoc's own cell split,
-- remains the single source of truth for that).
local function naive_cell_count(line)
  local s = line:match("^%s*(.-)%s*$"):gsub("^|", ""):gsub("|$", "")
  local _, n = s:gsub("|", "|")
  return n + 1
end

-- Detect and parse a run of consecutive `text` nodes that form a markdown
-- PIPE table (`| A | B |` / `|---|---|` / `| 1 | 2 |`) -- Notion's own
-- "Complete example" on the enhanced-markdown page uses this syntax
-- alongside the <table>/<tr>/<td> HTML form (spec §3; tests/corpus/official).
-- Liberal on read, canonical on write: a pipe table normalizes to <table>
-- when written back out, which is fine because byte-identity is already
-- waived -- only stability is required.
--
-- pandoc.read is both the parser AND the well-formedness check here: a run
-- of lines starting with "|" that is NOT a valid pipe table (a stray
-- literal "|" in prose, a malformed row) parses to something other than a
-- single Table block, so it returns nil and the caller falls through to
-- ordinary per-line paragraph handling -- this must never crash and never
-- silently swallow such a line.
local function pipe_table_run(nodes, i)
  if nodes[i].kind ~= "text" or not nodes[i].text:match("^|") then
    return nil
  end
  local j = i
  while j <= #nodes and nodes[j].kind == "text" and nodes[j].text:match("^|") do
    j = j + 1
  end
  local lines = {}
  for k = i, j - 1 do lines[#lines + 1] = nodes[k].text end

  local ok, doc = pcall(pandoc.read, table.concat(lines, "\n"), inlines.EXTENSIONS)
  if not ok or #doc.blocks ~= 1 or doc.blocks[1].t ~= "Table" then
    return nil
  end

  local tbl = doc.blocks[1]

  -- pandoc's pipe-tables grammar treats a delimiter row that
  -- UNDER-specifies columns relative to the header/data rows as valid --
  -- it silently narrows the whole table to match the delimiter instead of
  -- rejecting it, which drops entire columns of real content with no error
  -- and no [INFO]. Detect that by comparing the table's actual column
  -- count against the widest column count any non-delimiter source line
  -- implies (line 2 is always the delimiter row in a run pandoc has
  -- already accepted as one Table); if the table came out narrower, the
  -- parse lost data, so reject it and let the caller fall through to
  -- ordinary paragraph handling -- lossless, if less pretty, exactly like
  -- the not-a-table case above. A delimiter row that OVER-specifies
  -- columns is fine: pandoc pads the shorter rows instead of dropping
  -- anything, so no check is needed in that direction.
  local max_cols = 0
  for k = 1, #lines do
    if k ~= 2 then
      local n = naive_cell_count(lines[k])
      if n > max_cols then max_cols = n end
    end
  end
  if #tbl.colspecs < max_cols then
    return nil
  end

  local function fold_row(row)
    for _, cell in ipairs(row.cells) do
      cell.contents = pandoc.Blocks({
        pandoc.Plain(fold_pipe_cell(pandoc.utils.blocks_to_inlines(cell.contents))) })
    end
  end
  for _, row in ipairs(tbl.head.rows) do fold_row(row) end
  for _, body in ipairs(tbl.bodies) do
    for _, row in ipairs(body.body) do fold_row(row) end
  end

  return tbl, j
end

convert = function(nodes)
  local out, i = pandoc.Blocks({}), 1
  while i <= #nodes do
    local node = nodes[i]
    local pipe_table, after = pipe_table_run(nodes, i)

    if pipe_table then
      out:insert(pipe_table)
      i = after
    else
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
  end
  return out
end

-- An empty or whitespace-only chunk (a bare "# ", a bare ">", "<td></td>")
-- parses to ZERO blocks once joined with "\n\n" into the batch, which
-- desyncs M.prime's `#doc.blocks ~= #texts` guard and discards the WHOLE
-- batch -- paying a wasted priming read AND a per-chunk read for every
-- other line in the document. Such a chunk parses to nothing anyway, so
-- priming it is pure downside; gather() drops it instead of collecting it.
-- Deliberately the reader's OWN test (inlines.is_blank), not a second copy:
-- what gather() skips and what inlines.read short-circuits must agree.
local is_blank = inlines.is_blank

-- Gather every leaf inline run in the tree so they can be parsed in one pass.
-- leaf_text() is the same function block_for() itself uses to decide what to
-- hand to inlines.read(), so the primed cache key and the lookup key can
-- never disagree -- except for a real <table>'s cells, whose read text is
-- context-dependent (see cell_text above): a "table" node's rows are walked
-- separately here, the same way table_block() walks them, using the
-- matching cell_text() rather than leaf_text()'s context-free (and for
-- "td", therefore wrong) fallback. Only ever a chunk some reader will
-- actually request: leaf_text/cell_text already return nil for a node whose
-- text is never looked up (code, math, table structure other than cells,
-- container nodes), and is_blank drops the ones that ARE looked up but
-- parse to nothing.
local function gather(nodes, acc)
  for _, node in ipairs(nodes) do
    if node.tag == "table" then
      for _, tr in ipairs(node.children) do
        if tr.tag == "tr" then
          for _, td in ipairs(tr.children) do
            if td.tag == "td" then
              local text = cell_text(td)
              if text and not is_blank(text) then acc[#acc + 1] = text end
              gather(td.children, acc)
            end
          end
        end
      end
    else
      local text = leaf_text(node)
      if text and not is_blank(text) then acc[#acc + 1] = text end
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
