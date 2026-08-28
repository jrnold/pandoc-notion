local M = { passed = 0, failed = 0, failures = {} }

-- Deterministic rendering used for deep comparison and for failure messages.
-- Array part is rendered in index order; hash part is sorted by key name.
local function fmt(v)
  if type(v) ~= "table" then return string.format("%q", tostring(v)) end
  local parts, n = {}, #v
  for i = 1, n do parts[#parts + 1] = fmt(v[i]) end
  local keys = {}
  for k in pairs(v) do
    local is_index = type(k) == "number" and k % 1 == 0 and k >= 1 and k <= n
    if not is_index then keys[#keys + 1] = k end
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do
    parts[#parts + 1] = string.format("%s=%s", tostring(k), fmt(v[k]))
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end
M.fmt = fmt

function M.eq(actual, expected, msg)
  local a, e = fmt(actual), fmt(expected)
  if a == e then
    M.passed = M.passed + 1
  else
    M.failed = M.failed + 1
    M.failures[#M.failures + 1] = string.format(
      "%s\n    expected: %s\n    actual:   %s", msg or "eq", e, a)
  end
end

function M.truthy(v, msg)
  if v then M.passed = M.passed + 1
  else
    M.failed = M.failed + 1
    M.failures[#M.failures + 1] = (msg or "truthy") .. "\n    got falsy"
  end
end

function M.report()
  for _, f in ipairs(M.failures) do io.stderr:write("FAIL: " .. f .. "\n") end
  io.write(string.format("%d passed, %d failed\n", M.passed, M.failed))
  return M.failed == 0 and 0 or 1
end

return M
