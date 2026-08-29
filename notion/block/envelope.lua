-- Accepts the three shapes real callers actually have on hand, and unwraps
-- each to a block array plus an optional page object (design doc 6.1).
local json = require "notion.block.json"

local M = {}

local ACCEPTED = "expected a bare array of blocks, a list response " ..
                 '({"object":"list","results":[...]}), or a page object ' ..
                 '({"object":"page","properties":{...}})'

local function is_array(v)
  if type(v) ~= "table" then return false end
  if next(v) == nil then return true end     -- empty: treat as an empty array
  return v[1] ~= nil
end

function M.unwrap(value)
  if type(value) ~= "table" then
    error("notion-block-reader: " .. ACCEPTED, 0)
  end

  local object = json.get(value, "object")

  if object == "page" then
    local children = json.get(value, "children") or json.get(value, "results") or {}
    return json.arr(children), value
  end

  if object == "list" then
    return json.arr(json.get(value, "results") or {}), nil
  end

  -- No `object` discriminator: it is either a bare array or not our format.
  if is_array(value) then
    return json.arr(value), nil
  end

  error("notion-block-reader: " .. ACCEPTED, 0)
end

return M
