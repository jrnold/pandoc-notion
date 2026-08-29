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
    elseif tag and kind == "close" then
      out:insert(pandoc.Str(il.text))       -- stray close: literal, not RawInline
      i = i + 1
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
                             pandoc.Attr("", { "citation" },
                                         attr.ordered({ url = url }, { "url" }))))
    else
      out:insert(il)
    end
  end
  return out
end

-- markdown_strict treats 4+ leading spaces as an indented code block, which
-- blocks_to_inlines flattens to an inline Code span -- turning e.g.
-- "    **bold**" into a literal Code span instead of Strong. NFM has no
-- notion of leading-space indentation at the inline level (the container
-- rule already strips any that is meaningful), so trim it before handing
-- text to pandoc.read rather than let markdown_strict's block-level rule
-- leak into inline parsing.
local function trim_leading(text)
  return text:gsub("^[ \t]+", "")
end

local cache = {}

function M.reset() cache = {} end

-- Parse many inline runs in ONE pandoc.read. Chunks are joined with a blank
-- line so pandoc keeps them as separate Paras, then mapped back positionally.
-- If the block count does not match, the batch is discarded entirely and the
-- per-chunk path is used, so correctness never depends on this working.
function M.prime(texts)
  if #texts == 0 then return end
  local joined = {}
  for i, text in ipairs(texts) do joined[i] = trim_leading(text) end
  local doc = pandoc.read(table.concat(joined, "\n\n"), M.EXTENSIONS)
  if #doc.blocks ~= #texts then return end     -- misaligned: fall back silently
  for i, text in ipairs(texts) do
    -- blocks_to_inlines, not block.content directly: a chunk that pandoc
    -- reparses as something other than a single Para (e.g. "> quoted
    -- looking" becoming a BlockQuote) still has SOME single block at this
    -- position, keeping the batch's block count aligned with #texts, but
    -- its .content is Blocks rather than Inlines for non-Para/Plain types.
    -- Routing every block through blocks_to_inlines -- the same call the
    -- per-chunk path below uses -- flattens it correctly regardless of
    -- block type instead of caching a type-mismatched value.
    local ils = pandoc.utils.blocks_to_inlines({ doc.blocks[i] })
    cache[text] = fold_citations(M.fold(ils))
  end
end

function M.read(text)
  local hit = cache[text]
  -- Return a clone, not the cached object itself: two reads of identical
  -- text must not hand back the SAME Inlines table (rawequal), or a future
  -- in-place mutation at one call site would silently corrupt every other
  -- occurrence of that line that shares the cache entry.
  if hit then return hit:clone() end
  local doc = pandoc.read(trim_leading(text), M.EXTENSIONS)
  local ils = pandoc.utils.blocks_to_inlines(doc.blocks)
  local result = fold_citations(M.fold(ils))
  cache[text] = result
  return result
end

return M
