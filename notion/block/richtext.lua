-- Notion rich text is a FLAT list of runs, each carrying a complete annotation
-- set. Pandoc's is a NESTED tree. Both halves of that inverse conversion live
-- here so the inverse property stays visible and testable in one place.
local json = require "notion.block.json"

local M = {}

-- Canonical wrapper order, outermost to innermost:
--   Link, Span(color), Strong, Emph, Underline, Strikeout, Code
-- Code is innermost by TYPE CONSTRAINT -- it holds a string, not inlines, so
-- Code[Strong[...]] cannot be constructed. The rest is pinned purely for
-- determinism: {bold,italic} maps equally well onto Strong[Emph[x]] and
-- Emph[Strong[x]], and an unpinned choice makes round trips flap.

local function annotations_of(rt)
  local a = json.get(rt, "annotations") or {}
  return {
    bold          = json.get(a, "bold") == true,
    italic        = json.get(a, "italic") == true,
    underline     = json.get(a, "underline") == true,
    strikethrough = json.get(a, "strikethrough") == true,
    code          = json.get(a, "code") == true,
    color         = json.color_to_ast(json.get(a, "color")),
  }
end

local function href_of(rt)
  local direct = json.get(rt, "href")
  if direct then return tostring(direct) end
  local text = json.get(rt, "text")
  local link = json.get(text, "link")
  local url  = json.get(link, "url")
  return url and tostring(url) or nil
end

-- Stable identity for coalescing: two runs merge only if every annotation and
-- the link target match exactly.
local function identity(a, href)
  return table.concat({
    tostring(a.bold), tostring(a.italic), tostring(a.underline),
    tostring(a.strikethrough), tostring(a.code),
    tostring(a.color or ""), tostring(href or ""),
  }, "\1")
end

-- Text content with embedded newlines becomes LineBreak, which is how Notion
-- renders a line break inside a single block.
local function text_inlines(s)
  local out, first = {}, true
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    if not first then out[#out + 1] = pandoc.LineBreak() end
    first = false
    for _, el in ipairs(pandoc.Inlines(line)) do out[#out + 1] = el end
  end
  return out
end

local function mention_span(rt)
  local mention = json.get(rt, "mention") or {}
  local kind    = tostring(json.get(mention, "type") or "unknown")
  local class   = "mention-" .. kind:gsub("_", "-")
  local payload = json.get(mention, kind) or {}

  local attrs = {}
  local url = json.get(payload, "url")
  local id  = json.get(payload, "id")
  if url then attrs[#attrs + 1] = { "url", tostring(url) }
  elseif id then attrs[#attrs + 1] = { "url", tostring(id) } end
  if kind == "date" then
    attrs = {}
    local start_ = json.get(payload, "start")
    local end_   = json.get(payload, "end")
    if start_ then attrs[#attrs + 1] = { "start", tostring(start_) } end
    if end_   then attrs[#attrs + 1] = { "end",   tostring(end_)   } end
  end

  local label = json.get(rt, "plain_text")
  local content = label and text_inlines(tostring(label)) or {}
  return pandoc.Span(content,
                     pandoc.Attr("", { "mention", class }, attrs))
end

-- The innermost node for one run. Code is built here, not wrapped, because it
-- takes a string.
local function leaf(rt, a, content)
  local kind = json.get(rt, "type")
  if kind == "equation" then
    local expr = json.get(json.get(rt, "equation") or {}, "expression")
    return { pandoc.Math("InlineMath", tostring(expr or "")) }
  end
  if kind == "mention" then
    return { mention_span(rt) }
  end
  if a.code then return { pandoc.Code(content) } end
  return text_inlines(content)
end

local function wrap(inlines, a, href)
  if a.strikethrough then inlines = { pandoc.Strikeout(inlines) } end
  if a.underline     then inlines = { pandoc.Underline(inlines) } end
  if a.italic        then inlines = { pandoc.Emph(inlines) } end
  if a.bold          then inlines = { pandoc.Strong(inlines) } end
  if a.color then
    inlines = { pandoc.Span(inlines,
                            pandoc.Attr("", {}, { { "color", a.color } })) }
  end
  if href then inlines = { pandoc.Link(inlines, href) } end
  return inlines
end

function M.to_inlines(rich_text)
  local out = pandoc.List({})
  if type(rich_text) ~= "table" then return pandoc.Inlines(out) end

  -- Pass 1: coalesce adjacent text runs sharing an identity. Mentions and
  -- equations are atomic and never merge.
  local runs = {}
  for _, rt in ipairs(rich_text) do
    local a       = annotations_of(rt)
    local kind    = json.get(rt, "type")
    -- href produces a Link only for text runs: mentions carry their URL in
    -- the Span's own url attribute (Link[mention] isn't valid NFM, and would
    -- duplicate the URL), and equations have no link semantics.
    local href    = (kind == "text" or kind == nil) and href_of(rt) or nil
    local id      = identity(a, href)
    local content = ""
    if kind == "text" or kind == nil then
      content = tostring(json.get(json.get(rt, "text") or {}, "content") or "")
    end
    local prev = runs[#runs]
    if kind == "text" and prev and prev.mergeable and prev.identity == id then
      prev.content = prev.content .. content
    else
      runs[#runs + 1] = {
        rt = rt, annotations = a, href = href, identity = id,
        content = content, mergeable = (kind == "text"),
      }
    end
  end

  -- Pass 2: wrap each coalesced run in canonical order.
  for _, run in ipairs(runs) do
    for _, el in ipairs(wrap(leaf(run.rt, run.annotations, run.content),
                            run.annotations, run.href)) do
      out:insert(el)
    end
  end
  return pandoc.Inlines(out)
end

-- ---------------------------------------------------------------------------
-- Write direction: nested tree -> flat runs.
--
-- The tree is walked with the annotation set inherited downward; one segment
-- is emitted per leaf, and adjacent leaves sharing a state merge. This
-- direction is MANY-TO-ONE (Strong[Link[x]] and Link[Strong[x]] encode
-- identically), which is why only from_inlines(to_inlines(x)) == x is asserted.
-- ---------------------------------------------------------------------------

local function new_state()
  return { bold = false, italic = false, underline = false,
           strikethrough = false, code = false, color = nil, href = nil }
end

local function derive(st, key, value)
  local copy = {}
  for k, v in pairs(st) do copy[k] = v end
  copy[key] = value
  return copy
end

local function annotations_for(st)
  return {
    bold          = st.bold,
    italic        = st.italic,
    strikethrough = st.strikethrough,
    underline     = st.underline,
    code          = st.code,
    color         = json.color_to_notion(st.color),
  }
end

local function state_identity(st)
  return table.concat({
    tostring(st.bold), tostring(st.italic), tostring(st.underline),
    tostring(st.strikethrough), tostring(st.code),
    tostring(st.color or ""), tostring(st.href or ""),
  }, "\1")
end

function M.from_inlines(inlines)
  local out  = json.arr()
  local meta = {}   -- parallel bookkeeping: identity + mergeability per entry

  local function emit_text(s, st)
    if s == "" then return end
    local id   = state_identity(st)
    local last = out[#out]
    if last and meta[#out] and meta[#out].mergeable and meta[#out].identity == id then
      last.text.content = last.text.content .. s
      last.plain_text   = last.text.content
      return
    end
    out:insert(json.obj({
      type = "text",
      text = json.obj({
        content = s,
        link    = st.href and json.obj({ url = st.href }) or nil,
      }),
      annotations = json.obj(annotations_for(st)),
      plain_text  = s,
      href        = st.href,
    }))
    meta[#out] = { identity = id, mergeable = true }
  end

  local function emit_atom(entry, st)
    out:insert(entry)
    meta[#out] = { identity = state_identity(st), mergeable = false }
  end

  local walk

  local function walk_span(el, st)
    local classes = el.classes or {}
    local is_mention = false
    local kind
    for _, c in ipairs(classes) do
      if c == "mention" then is_mention = true end
      local m = tostring(c):match("^mention%-(.+)$")
      if m then kind = m:gsub("%-", "_") end
    end
    if is_mention and kind then
      local payload = json.obj({})
      local url = el.attributes.url
      if kind == "date" then
        if el.attributes.start then payload.start = el.attributes.start end
        if el.attributes["end"] then payload["end"] = el.attributes["end"] end
      elseif url then
        payload.id = url
        payload.url = url
      end
      emit_atom(json.obj({
        type = "mention",
        mention = json.obj({ type = kind, [kind] = payload }),
        annotations = json.obj(annotations_for(st)),
        plain_text  = pandoc.utils.stringify(el),
        href        = st.href,
      }), st)
      return
    end
    local color = el.attributes and el.attributes.color
    walk(el.content, color and derive(st, "color", color) or st)
  end

  walk = function(ins, st)
    for _, el in ipairs(ins or {}) do
      local tag = el.t
      if     tag == "Str"       then emit_text(el.text, st)
      elseif tag == "Space"     then emit_text(" ", st)
      elseif tag == "SoftBreak" then emit_text(" ", st)
      elseif tag == "LineBreak" then emit_text("\n", st)
      elseif tag == "Strong"    then walk(el.content, derive(st, "bold", true))
      elseif tag == "Emph"      then walk(el.content, derive(st, "italic", true))
      elseif tag == "Underline" then walk(el.content, derive(st, "underline", true))
      elseif tag == "Strikeout" then walk(el.content, derive(st, "strikethrough", true))
      elseif tag == "Code"      then emit_text(el.text, derive(st, "code", true))
      elseif tag == "Link"      then walk(el.content, derive(st, "href", el.target))
      elseif tag == "Span"      then walk_span(el, st)
      elseif tag == "Math"      then
        emit_atom(json.obj({
          type = "equation",
          equation = json.obj({ expression = el.text }),
          annotations = json.obj(annotations_for(st)),
          plain_text  = el.text,
          href        = st.href,
        }), st)
      elseif el.content then
        -- Defined default: walk transparently. Task 11 replaces this with the
        -- documented lossy fallbacks for SmallCaps, Super/Subscript, Note,
        -- Quoted, Cite, RawInline and Image.
        walk(el.content, st)
      end
    end
  end

  walk(inlines, new_state())
  return out
end

return M
