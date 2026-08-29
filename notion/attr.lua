local M = {}

local BASE = { "gray", "brown", "orange", "yellow", "green",
               "blue", "purple", "pink", "red" }

M.COLORS = {}
for _, c in ipairs(BASE) do
  M.COLORS[c] = true
  M.COLORS[c .. "_bg"] = true
end

-- Currently unused by production code: nothing validates a colour attribute
-- on the way through -- an unknown value is carried across verbatim. Kept
-- (and unit-tested) for a future validating pass.
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

-- The same attribute list formatted for the inside of a TAG's `< >` rather
-- than as a trailing `{…}` prose suffix: M.render gives ` {k="v"}`, this
-- strips the braces and keeps the leading space, so a caller can write
-- `"<" .. tag .. tag_attrs(a, order) .. ">"` and get `<tag k="v">` or, when
-- there are no attributes at all, a bare `<tag>`.
--
-- ONE definition, shared by writer/blocks.lua and writer/inlines.lua. These
-- were two near-identical copies that disagreed on the leading space; four
-- separate bugs in this project came from two places computing the same
-- thing, so the space is now part of the contract rather than per-caller.
function M.tag_attrs(pairs_, order)
  return (M.render(pairs_, order):gsub("^ {", " "):gsub("}$", ""))
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
