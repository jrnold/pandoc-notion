local t = require "support.assert"
local json = require "notion.block.json"

-- Spec 2.1: the array/object distinction is invisible in Lua and fatal in Notion.
t.eq(json.encode(json.arr()), "[]", "empty array encodes as []")
t.eq(json.encode(json.obj()), "{}", "empty object encodes as {}")
t.eq(json.encode(json.arr({ 1, 2 })), "[1,2]", "array with items")
t.eq(json.encode(json.obj({ a = 1 })), '{"a":1}', "object with keys")

-- An array nested inside an object must still be an array.
t.eq(json.encode(json.obj({ rich_text = json.arr() })), '{"rich_text":[]}',
     "nested empty array stays an array")

-- Spec 2.4: null is truthy userdata, so get() must return nil for it.
local decoded = json.decode_or_diagnose('{"a":null,"b":1}')
t.truthy(decoded.a ~= nil, "raw null is present and truthy")
t.eq(json.get(decoded, "a"), nil, "get() returns nil for null")
-- Spec 2.5: decode yields FLOATS, so JSON 1 arrives as 1.0. Numerically equal
-- to 1, but t.eq compares stringified forms ("1.0" vs "1"), so assert the
-- value numerically and pin the float-ness separately -- it is the behaviour
-- props.lua's num_to_string exists to paper over.
t.truthy(json.get(decoded, "b") == 1, "get() returns real values")
t.eq(math.type(json.get(decoded, "b")), "float", "decoded numbers are floats")
t.eq(math.tointeger(json.get(decoded, "b")), 1, "and recover as integers")
t.eq(json.get(decoded, "missing"), nil, "get() returns nil for absent keys")
t.eq(json.get(nil, "a"), nil, "get() tolerates a nil container")

-- Spec 2.3: decode returns nil rather than raising; we must raise ourselves.
local ok, err = pcall(json.decode_or_diagnose, "{bad")
t.truthy(not ok, "malformed JSON raises")
t.truthy(tostring(err):find("{bad", 1, true), "the diagnostic quotes the input")
local ok2 = pcall(json.decode_or_diagnose, "")
t.truthy(not ok2, "empty input raises")

-- Spec 4.2: colour spelling differs between NFM and the API.
t.eq(json.color_to_ast("default"), nil, "default means no attribute")
t.eq(json.color_to_ast(nil), nil, "absent means no attribute")
t.eq(json.color_to_ast("blue"), "blue", "plain hues pass through")
t.eq(json.color_to_ast("blue_background"), "blue_bg", "_background becomes _bg")
t.eq(json.color_to_notion(nil), "default", "no attribute means default")
t.eq(json.color_to_notion("blue"), "blue", "plain hues pass through")
t.eq(json.color_to_notion("blue_bg"), "blue_background", "_bg becomes _background")

-- Round trip over every legal colour.
for _, hue in ipairs({ "gray", "brown", "orange", "yellow", "green",
                       "blue", "purple", "pink", "red" }) do
  t.eq(json.color_to_ast(json.color_to_notion(hue)), hue, hue .. " round-trips")
  t.eq(json.color_to_ast(json.color_to_notion(hue .. "_bg")), hue .. "_bg",
       hue .. "_bg round-trips")
end
