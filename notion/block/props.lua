-- Page properties -> pandoc Meta. Read direction only: property WRITES must
-- validate against a database schema (a select value must already exist as an
-- option), which is the API client's job. See design doc 4.6 and 12.2.
local json     = require "notion.block.json"
local richtext = require "notion.block.richtext"

local M = {}

-- Decode yields floats, so 87 arrives as 87.0. Render integral values without
-- a decimal part.
local function num_to_string(n)
  local i = math.tointeger(n)
  if i then return tostring(i) end
  return tostring(n)
end

local function names_of(list, key)
  local out = {}
  for _, item in ipairs(list or {}) do
    local v = json.get(item, key)
    if v ~= nil then out[#out + 1] = tostring(v) end
  end
  return out
end

-- Resolve a formula or rollup to whichever typed field it carries.
local function resolve_value(v)
  if v == nil then return nil end
  local kind = json.get(v, "type")
  local inner = kind and json.get(v, kind) or nil
  if inner == nil then return nil end
  if type(inner) == "number" then return num_to_string(inner) end
  if type(inner) == "boolean" then return inner end
  if type(inner) == "table" then
    local start_ = json.get(inner, "start")
    if start_ then return tostring(start_) end
    return nil
  end
  return tostring(inner)
end

local DISPATCH = {
  title = function(p)
    return pandoc.MetaInlines(richtext.to_inlines(json.get(p, "title")))
  end,
  rich_text = function(p)
    return pandoc.MetaInlines(richtext.to_inlines(json.get(p, "rich_text")))
  end,
  number = function(p)
    local n = json.get(p, "number")
    return n and num_to_string(n) or nil
  end,
  select = function(p)
    local v = json.get(p, "select")
    local name = json.get(v, "name")
    return name and tostring(name) or nil
  end,
  status = function(p)
    local v = json.get(p, "status")
    local name = json.get(v, "name")
    return name and tostring(name) or nil
  end,
  multi_select = function(p) return names_of(json.get(p, "multi_select"), "name") end,
  people       = function(p) return names_of(json.get(p, "people"), "name") end,
  relation     = function(p) return names_of(json.get(p, "relation"), "id") end,
  date = function(p)
    local d = json.get(p, "date")
    local start_ = json.get(d, "start")
    if not start_ then return nil end
    local end_ = json.get(d, "end")
    if end_ then return tostring(start_) .. "/" .. tostring(end_) end
    return tostring(start_)
  end,
  checkbox = function(p)
    local v = json.get(p, "checkbox")
    if v == nil then return nil end
    return v == true
  end,
  url          = function(p) local v = json.get(p, "url");          return v and tostring(v) or nil end,
  email        = function(p) local v = json.get(p, "email");        return v and tostring(v) or nil end,
  phone_number = function(p) local v = json.get(p, "phone_number"); return v and tostring(v) or nil end,
  files = function(p)
    local out = {}
    for _, f in ipairs(json.get(p, "files") or {}) do
      local kind = json.get(f, "type")
      local url  = kind and json.get(json.get(f, kind), "url") or nil
      if url then out[#out + 1] = tostring(url) end
    end
    return out
  end,
  formula = function(p) return resolve_value(json.get(p, "formula")) end,
  rollup  = function(p) return resolve_value(json.get(p, "rollup")) end,
  created_time      = function(p) local v = json.get(p, "created_time");      return v and tostring(v) or nil end,
  last_edited_time  = function(p) local v = json.get(p, "last_edited_time");  return v and tostring(v) or nil end,
  created_by = function(p)
    local name = json.get(json.get(p, "created_by"), "name")
    return name and tostring(name) or nil
  end,
  last_edited_by = function(p)
    local name = json.get(json.get(p, "last_edited_by"), "name")
    return name and tostring(name) or nil
  end,
}

function M.to_meta(properties)
  local meta = {}
  if type(properties) ~= "table" then return meta end

  -- Sorted for deterministic log order; Lua's pairs() order is arbitrary.
  local names = {}
  for name in pairs(properties) do names[#names + 1] = name end
  table.sort(names)

  for _, name in ipairs(names) do
    local prop = properties[name]
    local kind = json.get(prop, "type")
    local handler = kind and DISPATCH[kind] or nil
    if handler then
      local value = handler(prop)
      if value ~= nil then
        meta[name] = value
        -- Notion names the title column whatever the database calls it, so
        -- --standalone output would otherwise go untitled.
        if kind == "title" and meta.title == nil then meta.title = value end
      end
    elseif kind then
      pandoc.log.info("Not converting page property of type " .. tostring(kind))
    end
  end
  return meta
end

return M
