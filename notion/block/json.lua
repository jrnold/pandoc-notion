-- Central owner of the two pandoc.json behaviours that fail silently and
-- non-locally (design doc 2.1 and 2.4):
--   * a bare {} encodes as a JSON object, where Notion requires an array
--   * null decodes to a TRUTHY userdata singleton
-- Every array in this project is built with arr(); every optional field is
-- read through get().
local M = {}

local pjson = pandoc.json

-- A JSON array. Must be a pandoc.List: a plain table encodes as {}.
function M.arr(t)
  return pandoc.List(t or {})
end

-- A JSON object. A plain table is correct here.
function M.obj(t)
  return t or {}
end

-- Field access that treats JSON null exactly like an absent key.
function M.get(t, key)
  if type(t) ~= "table" then return nil end
  local v = t[key]
  if v == nil or v == pjson.null then return nil end
  return v
end

function M.encode(v)
  return pjson.encode(v)
end

-- pandoc.json.decode returns nil on malformed input and never raises, so a
-- pcall around it is useless -- the nil must be checked for here, or the
-- failure resurfaces much later as something unrelated.
function M.decode_or_diagnose(text)
  local value = pjson.decode(text)
  if value == nil then
    local head = tostring(text):sub(1, 80)
    error("notion-block-reader: input is not valid JSON, starting: " .. head, 0)
  end
  return value
end

-- Colour spelling differs between the two formats. The shared AST keeps NFM's
-- form; this pair translates at its own boundary. "default" is spelled as the
-- absence of the attribute.
function M.color_to_ast(c)
  if c == nil or c == pjson.null or c == "default" then return nil end
  local hue = tostring(c):match("^(.*)_background$")
  if hue then return hue .. "_bg" end
  return tostring(c)
end

function M.color_to_notion(c)
  if c == nil or c == "" then return "default" end
  local hue = tostring(c):match("^(.*)_bg$")
  if hue then return hue .. "_background" end
  return tostring(c)
end

return M
