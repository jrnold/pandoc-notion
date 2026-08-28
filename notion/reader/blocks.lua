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

-- Build one <table> node into a native pandoc Table/Row/Cell. Table cells
-- hold rich text only (never block content), so each <td>'s inner text is
-- read straight through inlines.read. A <colgroup>/<col> child, if present,
-- has nowhere to land in pandoc's Table model (no per-column Attr slot) and
-- is simply not a <tr>, so the loop below already skips it -- it is parsed
-- out of node.children and otherwise ignored, per Ruling F1.
local function table_block(node)
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
        local content = inlines.read(inline_label(td.text))
        cells[#cells + 1] = pandoc.Cell(
          pandoc.Blocks({ pandoc.Plain(content) }),
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

  -- Table-level attributes other than header-row/header-column (e.g.
  -- fit-page-width) go on the Table's own Attr.
  local a, order = {}, {}
  for _, k in ipairs(node.attr_order) do
    if k ~= "header-row" and k ~= "header-column" then
      a[k] = node.attrs[k]; order[#order + 1] = k
    end
  end

  return pandoc.Table(
    pandoc.Caption(nil, {}),
    colspecs,
    pandoc.TableHead(head_rows, pandoc.Attr()),
    { pandoc.TableBody(body_rows, {}, 0, pandoc.Attr()) },
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
        kids = pandoc.Blocks({ pandoc.Plain(inlines.read(inline_label(node.text))) })
      end
      return pandoc.Div(kids, attr_of(node, { def.class }))
    end
    local media = schema.MEDIA_TAGS[tag]
    if media then
      local caption = inlines.read(inline_label(node.text))
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
